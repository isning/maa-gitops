# maa-gitops

GitOps manifests for running [MAA (MaaAssistantArknights)](https://github.com/MaaAssistantArknights/MaaAssistantArknights) daily tasks inside [Redroid](https://github.com/remote-android/redroid-doc) Android containers on Kubernetes, managed by [redroid-operator](https://github.com/isning/redroid-operator).

## Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  Kubernetes cluster                                                 │
│                                                                     │
│  ┌──────────────────┐        ┌───────────────────────────────────┐  │
│  │ RedroidInstance  │        │  RedroidTask (CronJob)            │  │
│  │ (per-account)    │◄──ADB──│  integration: maa-cli             │  │
│  └──────────────────┘        │  wakeInstance: true               │  │
│         │                    └───────────────────────────────────┘  │
│  ┌──────┴───────────────────────────────────────────┐               │
│  │  redroid-data-base-pvc  (shared, read-only lower)│               │
│  │  redroid-data-diff-pvc  (per-instance upper)     │               │
│  └──────────────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────────────┘
```

### Design Principles

- **Suspend-by-default** — all `RedroidInstance` resources use `spec.suspend: true`. Instances are only started when needed: automatically by `RedroidTask` (via `wakeInstance: true`), or manually via `kubectl redroid` CLI. This avoids running GPU-heavy Android containers 24/7.
- **Overlayfs storage** — each instance uses two PVC layers:
  - `/data-base` — shared base PVC (read-only lower layer, populated once via `base-init`)
  - `/data-diff/<index>` — per-account PVC subpath (writable upper layer, private data)
- **GitOps-compatible operations** — tasks and CLI commands modify `status` fields (`.status.woken`, `.status.suspended`), not `spec`. Manual operations do not cause reconciliation drift.
- **Per-instance config** — connection profile is shared (`maa-profile` ConfigMap, mounted at task level), while each account has its own dedicated `maa-tasks-<instance>` ConfigMap containing a single `default.toml` task file, following [maa-cli's directory convention](https://github.com/MaaAssistantArknights/maa-cli/blob/main/crates/maa-cli/docs/en-US/config.md). The per-instance ConfigMap is mounted via `InstanceRef.volumes/volumeMounts`, so the run command is always the static `maa run default --batch`.

## Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` | Kubernetes CLI |
| `kubectl-redroid` | redroid-operator plugin — instance management, port-forward, ADB |
| `flux` (optional) | GitOps reconciliation |
| `adb` (optional) | Required for `kubectl redroid instance adb/shell` |

Install `kubectl-redroid`:
```bash
# From redroid-operator repo
make install-plugin
# or: go install github.com/isning/redroid-operator/cmd/kubectl-redroid@latest
```

## Repository Structure

```
manifests/
  kustomization.yaml          # Kustomization — all app resources
  redroid-pvc.yaml            # PersistentVolumeClaims (base + diff)
  redroid-instances.yaml      # RedroidInstance definitions
  maa-profile.yaml            # ConfigMap: shared maa-cli connection profile
  maa-instance-tasks.yaml     # ConfigMaps: per-instance maa-cli task files (one CM per instance)
  base.yaml                   # Shared base instance + init/update tasks
  maa-task.yaml               # RedroidTask: daily CronJob
example/
  maa-wakeinstance-task.yaml  # Extension example: manual on-demand run

scripts/
  maa.sh                      # Helper script for complex operational workflows
  validate.sh                 # CI manifest validation (from Flux example)
  test_scripts.sh             # Unit tests for init/update scripts
```

## Quick Start

### 1. Install the operator

This repo contains only the application manifests. Install [redroid-operator](https://github.com/isning/redroid-operator) separately before deploying:

```bash
helm install redroid-operator oci://ghcr.io/isning/charts/redroid-operator \
  --namespace redroid-system --create-namespace
```

Or with Flux (tracks upgrades automatically):

```bash
# Add HelmRepository and HelmRelease from the redroid-operator repo:
# https://github.com/isning/redroid-operator/tree/main/charts
flux create source helm redroid-operator \
  --url=https://isning.github.io/redroid-operator \
  --namespace=redroid-system
flux create helmrelease redroid-operator \
  --chart=redroid-operator \
  --source=HelmRepository/redroid-operator \
  --namespace=redroid-system
```

### 2. Initialise the base layer (once)

The shared base PVC must be populated before normal instances can start. Everything is **Flux-managed** — `base.yaml` is included in `kustomization.yaml`.

```bash
# Interactive helper — suspends running instances, re-triggers the base-init task,
# follows logs, and prints scrcpy instructions for the manual step:
./scripts/maa.sh base-init
```

#### Init Flow Detail

```
┌────────────────────────────────────────────────────────────────────────────┐
│                          base-init Task Flow                               │
├───────────────┬────────────────────────────────────────────────────────────┤
│   Stage       │   What happens                                             │
├───────────────┼────────────────────────────────────────────────────────────┤
│  AUTOMATIC    │  1. Task triggers with wakeInstance: true                  │
│               │  2. base instance starts (index 255, baseMode: true)       │
│               │  3. Script downloads Arknights APK (~2GB)                  │
│               │  4. Script installs APK via ADB                            │
│               │  5. Script runs `sleep infinity` — Job stays alive         │
├───────────────┼────────────────────────────────────────────────────────────┤
│  MANUAL       │  6. You connect: scrcpy -s $(kubectl redroid instance      │
│               │       port-forward base --print-address)                   │
│               │  7. Open Arknights in the emulator                         │
│               │  8. Accept EULA, click through initial screens             │
│               │  9. Start in-game resource download (~1.5GB)               │
│               │ 10. Wait for download to complete                          │
│               │ 11. Exit the game (back to Android home)                   │
├───────────────┼────────────────────────────────────────────────────────────┤
│  CLEANUP      │ 12. Delete the Job:                                        │
│               │       kubectl delete job -l redroid.isning.moe/task=base-init      │
│               │ 13. base instance stops automatically                      │
│               │     (wakeInstance clears status.woken when Job ends)       │
└───────────────┴────────────────────────────────────────────────────────────┘
```

**Why `sleep infinity`?**  
The in-game resource download cannot be automated reliably (EULA acceptance, captcha, network variability). The script keeps the Job alive so you can complete setup at your own pace. Once you delete the Job, the operator clears `status.woken` and the `base` instance stops automatically.

**TL;DR:**
- APK install is **automatic** (no action needed)
- Game data download is **manual** (connect via scrcpy, ~10 min)
- Instance shutdown is **triggered by you** deleting the Job

### 3. Apply the GitOps manifests

```bash
# App resources (instances, tasks, PVCs) — set your target namespace:
kubectl apply -k manifests/ -n <namespace>
```

Edit the YAML files to match your accounts and schedule.

## Operations

### Check status

```bash
./scripts/maa.sh status
# or individually:
kubectl redroid instance list
kubectl redroid task list
```

### Manually trigger the daily task

```bash
kubectl redroid task trigger maa-daily --watch
# or:
./scripts/maa.sh status  # then trigger manually
```

### Run MAA on-demand (without waiting for schedule)

Use the example one-shot task to trigger MAA immediately on specific instances:

```bash
kubectl apply -f example/maa-wakeinstance-task.yaml
kubectl get redroidinstances -w   # Stopped → Running → Stopped
```

`wakeInstance: true` tells the operator to temporarily start the instance, run the Job, then stop it. `spec.suspend` is not modified.

To re-run, delete the completed task first:

```bash
kubectl delete redroidtask maa-wake-run
kubectl apply -f example/maa-wakeinstance-task.yaml
```

### Manually start an instance (outside of tasks)

Since instances are suspended by default, you need to temporarily start them for manual operations (e.g. login to the game, install an app, debug).

```bash
# Temporarily resume an instance (modifies status only, not spec)
kubectl redroid instance resume maa-0

# Connect via scrcpy for visual interaction
scrcpy -s $(kubectl redroid instance port-forward maa-0 --print-address)

# Or port-forward and use ADB directly
kubectl redroid instance port-forward maa-0
adb connect 127.0.0.1:5555
adb shell

# When done, suspend it again
kubectl redroid instance suspend maa-0
```

> **Note:** `resume` / `suspend` modify `status.suspended`, not `spec.suspend`. The instance will also be started automatically by any `RedroidTask` with `wakeInstance: true` — no manual resume needed for scheduled tasks.

### ADB & shell access

```bash
# Run ADB commands on a running instance
kubectl redroid instance adb maa-0 -- devices
kubectl redroid instance adb maa-0 -- install /path/to/app.apk

# Interactive shell inside the Android container
kubectl redroid instance shell maa-0
```

### Suspend / resume

```bash
# Temporary suspend with reason and auto-expiry (modifies status only)
kubectl redroid instance suspend maa-0 --reason "maintenance" --duration 2h

# Manual resume
kubectl redroid instance resume maa-0

# Permanent suspend (spec change — Flux reconciles this)
kubectl patch redroidinstances maa-0 --type=merge -p '{"spec":{"suspend":true}}'
```

### Instance logs

```bash
kubectl redroid instance logs maa-0 --follow
```

### Update the base layer

The `base-update` task (in `base.yaml`) runs daily at 03:00 Asia/Shanghai. It checks the official version API and re-downloads if a new APK or resource version is detected. The task uses `wakeInstance: true` to temporarily start the shared `base` instance.

```bash
# Manual trigger:
./scripts/maa.sh base-update

# Watch logs:
kubectl -n default logs -l redroid.isning.moe/task=base-update -c update-script -f
```

> **Note:** The update script automatically handles overlayfs safety by running in `baseMode` (writes directly to base PVC while normal instances are using cached lower layers).

## Per-Instance MAA Configs

Configs follow the [maa-cli directory convention](https://github.com/MaaAssistantArknights/maa-cli/blob/main/crates/maa-cli/docs/en-US/config.md):

```
$MAA_CONFIG_DIR/
  profiles/
    default.toml     # connection settings (shared by all instances)
  tasks/
    0.toml           # task list for account 0
    1.toml           # task list for account 1
    ...
```

This is split into two layers so that the connection profile is shared while each instance has its own isolated task config:

| ConfigMap | Content | Mount scope | Mount point |
|-----------|---------|-------------|-------------|
| `maa-profile` | `default.toml` — connection & instance options | Task-level (`spec.volumes`) | `/etc/maa/profiles/default.toml` |
| `maa-tasks-<instance>` | `default.toml` — task list for that account | Instance-level (`spec.instances[].volumes`) | `/etc/maa/tasks/default.toml` |

Each instance mounts its own ConfigMap via `InstanceRef.volumes/volumeMounts`, so the command is static and identical for every instance:

```yaml
# task-level: shared connection profile
volumes:
  - name: maa-profile
    configMap:
      name: maa-profile
      items:
        - key: default.toml
          path: profiles/default.toml

# instance-level: per-instance task file
instances:
  - name: maa-0
    volumes:
      - name: maa-tasks
        configMap:
          name: maa-tasks-maa-0   # dedicated CM for this instance
    volumeMounts:
      - name: maa-tasks
        mountPath: /etc/maa/tasks
        readOnly: true

integrations:
  - name: maa-cli
    command: ["/bin/sh", "-c"]
    args: ["export MAA_CONFIG_DIR=/etc/maa && exec maa run default --batch"]
    volumeMounts:
      - name: maa-profile
        mountPath: /etc/maa
        readOnly: true
      # maa-tasks is injected per-instance above — no task-level mount needed
```

To customise an account's MAA tasks, edit the `default.toml` in its dedicated ConfigMap in `manifests/maa-instance-tasks.yaml`:

```yaml
# maa-instance-tasks.yaml — example entry for instance maa-0
apiVersion: v1
kind: ConfigMap
metadata:
  name: maa-tasks-maa-0
data:
  "default.toml": |
    [[tasks]]
    type = "StartUp"
    [tasks.params]
    client_type = "Official"
    start_game_enabled = true

    [[tasks]]
    type = "Infrast"
    [tasks.params]
    mode = 10000
    facility = ["Mfg", "Trade", "Control", "Recruit", "Power", "Reception", "Office", "Dorm"]

    [[tasks]]
    type = "Fight"
    [tasks.params]
    stage = "1-7"
    medicine = 3

    [[tasks]]
    type = "Mall"

    [[tasks]]
    type = "Award"
```

The connection profile in `manifests/maa-profile.yaml` is shared and rarely needs editing:

```yaml
# maa-profile.yaml
data:
  "default.toml": |
    [connection]
    adb_path = "adb"
    address = "127.0.0.1:5555"

    [instance_options]
    touch_mode = "ADB"
```

See the [maa-cli configuration reference](https://github.com/MaaAssistantArknights/maa-cli/blob/main/crates/maa-cli/docs/en-US/config.md) for all available task types and parameters.

## Adding More Accounts

### On-demand only

1. Add a `RedroidInstance` in `manifests/redroid-instances.yaml`.
2. Add a new `maa-tasks-<instance>` ConfigMap in `manifests/maa-instance-tasks.yaml` (copy the template at the bottom of that file).
3. Edit `example/maa-wakeinstance-task.yaml` to target the new instance with its `volumes`/`volumeMounts`.

### Daily automatic schedule

1. **Add a `RedroidInstance`** in `manifests/redroid-instances.yaml`:

   ```yaml
   ---
   apiVersion: redroid.isning.moe/v1alpha1
   kind: RedroidInstance
   metadata:
     name: maa-2
   spec:
     index: 2
     image: redroid/redroid:16.0.0-latest
     suspend: true    # kept suspended; wakeInstance in maa-task.yaml starts it only when needed
     sharedDataPVC: redroid-data-base-pvc
     diffDataPVC: redroid-data-diff-pvc
     gpuMode: host
   ```

2. **Add the MAA task ConfigMap** in `manifests/maa-instance-tasks.yaml`:

   ```yaml
   ---
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: maa-tasks-maa-2
   data:
     "default.toml": |
       [[tasks]]
       type = "StartUp"
       [tasks.params]
       client_type = "Official"
       start_game_enabled = true

       [[tasks]]
       type = "Fight"
       [tasks.params]
       stage = "1-7"
       medicine = 3

       [[tasks]]
       type = "Award"
   ```

3. **Update `manifests/maa-task.yaml`** — add the instance with its volume binding:

   ```yaml
   spec:
     instances:
       - name: <existing-instances...>
       - name: maa-2              # new
         volumes:
           - name: maa-tasks
             configMap:
               name: maa-tasks-maa-2
         volumeMounts:
           - name: maa-tasks
             mountPath: /etc/maa/tasks
             readOnly: true
   ```

4. Commit and push — Flux reconciles automatically.

## Instance Lifecycle & Suspend Priority

Instances are normally kept suspended (`spec.suspend: true`) and only started when needed:

| Trigger | How it starts the instance | Modifies |
|---------|---------------------------|----------|
| `RedroidTask` with `wakeInstance: true` | Sets `status.woken` → Pod starts → Job runs → clears `status.woken` → Pod stops | status only |
| `kubectl redroid instance resume` | Clears `status.suspended` → Pod starts | status only |
| `kubectl redroid instance suspend` | Sets `status.suspended` → Pod stops | status only |
| Edit `spec.suspend` in Git | Flux reconciles the spec change | spec |

The operator resolves the desired state with this priority:

```
status.woken  >  spec.suspend  >  status.suspended  >  default (Running)
```

- `status.woken = true` always wins → instance runs regardless of `spec.suspend`
- `spec.suspend = true` stops the instance unless overridden by `status.woken`
- `status.suspended` is a temporary operator-managed flag
- If nothing is set, the instance runs by default

## scripts/maa.sh Reference

```
./scripts/maa.sh status              Show all instances and tasks
./scripts/maa.sh base-init           Initialise /data-base PVC (first time only)
./scripts/maa.sh base-update         Trigger base APK/resource update task
./scripts/maa.sh wake-run [--watch]  Apply on-demand task from example/
```

For simple operations, use kubectl-redroid directly:

```
kubectl redroid task trigger maa-daily        # Trigger daily task
kubectl redroid instance suspend maa-0        # Suspend instance
kubectl redroid instance resume maa-0         # Resume instance
kubectl redroid instance logs maa-0 -f        # Follow logs
```

`NAMESPACE` environment variable overrides the target namespace (default: `default`).

## Tests

Run unit tests for the init/update scripts:

```bash
./scripts/test_scripts.sh              # Run all tests
./scripts/test_scripts.sh --no-network # Skip network-dependent tests
```

The test suite validates:
- Version parsing logic (JSON extraction with grep/sed)
- Version comparison logic (same version, APK change, resource-only change)
- Download monitor logic (size change detection, idle timeout)
- ADB timeout logic
- Shell script syntax (`sh -n`, `shellcheck`)
- Kustomize build integrity
- External API availability (Version API, APK download URL)
