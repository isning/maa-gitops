#!/usr/bin/env bash
# =============================================================================
# MAA-GitOps Helper Script
# =============================================================================
#
# Convenience wrapper for complex multi-step MAA operations.
# For simple commands, use kubectl-redroid directly:
#   kubectl redroid instance list/suspend/resume/logs
#   kubectl redroid task list/trigger
#
# Prerequisites:
#   kubectl         — standard kubectl, pointing at your cluster
#   kubectl-redroid — kubectl plugin from redroid-operator
#
# Usage:
#   ./scripts/maa.sh status              — show instances and tasks
#   ./scripts/maa.sh base-init           — initialise /data-base PVC (run once)
#   ./scripts/maa.sh base-update         — trigger base APK/resource update
#   ./scripts/maa.sh wake-run [--watch]  — apply on-demand task from example/
#
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../manifests" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/../example" && pwd)"

usage() {
  sed -n '/^# Usage:/,/^# ===/p' "$0" | grep '^#' | sed 's/^# \?//'
  exit 1
}

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "error: '$cmd' not found in \$PATH" >&2
      exit 1
    fi
  done
}

# ---------------------------------------------------------------------------
# status — quick overview of instances and tasks
# ---------------------------------------------------------------------------
cmd_status() {
  require_cmd kubectl
  echo "=== RedroidInstances ==="
  kubectl redroid instance list -n "$NAMESPACE" 2>/dev/null \
    || kubectl -n "$NAMESPACE" get redroidinstances -o wide
  echo ""
  echo "=== RedroidTasks ==="
  kubectl redroid task list -n "$NAMESPACE" 2>/dev/null \
    || kubectl -n "$NAMESPACE" get redroidtasks
}

# ---------------------------------------------------------------------------
# base-init — first-time shared base PVC initialisation
# ---------------------------------------------------------------------------
cmd_base_init() {
  require_cmd kubectl

  echo "This will trigger the base-init task to download and install the Arknights APK."
  echo ""
  echo "WARNING: All normal instances will be temporarily suspended."
  echo ""
  read -r -p "Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

  # Temporarily suspend all running normal instances (excluding 'base')
  local suspended_instances=()
  for inst in $(kubectl -n "$NAMESPACE" get redroidinstances \
      -o jsonpath='{range .items[?(@.spec.suspend==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -v '^base$'); do
    echo "  Suspending $inst..."
    kubectl redroid instance suspend -n "$NAMESPACE" "$inst" \
      --actor maa.sh --reason base-init 2>/dev/null || true
    suspended_instances+=("$inst")
  done

  echo ""
  echo "Re-triggering base-init task..."
  kubectl -n "$NAMESPACE" delete redroidtask base-init 2>/dev/null || true
  sleep 2
  kubectl -n "$NAMESPACE" apply -k "$APP_DIR" 2>/dev/null \
    || echo "(Flux will reconcile shortly)"

  echo ""
  echo "Waiting for base instance to start..."
  kubectl -n "$NAMESPACE" wait redroidinstance base \
    --for=jsonpath='{.status.phase}'=Running --timeout=180s 2>/dev/null \
    || echo "(check: kubectl redroid instance list)"

  echo ""
  echo "Following init-script logs..."
  echo "(Press Ctrl-C when you see manual-step instructions)"
  echo ""
  sleep 5
  kubectl -n "$NAMESPACE" logs -l redroid.isning.moe/task=base-init \
    -c init-script --follow --pod-running-timeout=120s 2>/dev/null || true

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo " MANUAL STEP REQUIRED"
  echo "════════════════════════════════════════════════════════════════════"
  echo ""
  echo "Connect to the instance:"
  echo "  kubectl redroid instance port-forward base --local-port 15556 &"
  echo "  scrcpy -s 127.0.0.1:15556"
  echo ""
  echo "In the emulator:"
  echo "  1. Open Arknights"
  echo "  2. Accept EULA"
  echo "  3. Start resource download (~1.5GB)"
  echo "  4. Wait for completion, then exit game"
  echo ""
  echo "When done, delete the Job:"
  echo "  kubectl -n $NAMESPACE delete job -l redroid.isning.moe/task=base-init"
  echo ""
  echo "The base instance stops automatically. Resume normal instances:"
  for inst in "${suspended_instances[@]}"; do
    echo "  kubectl redroid instance resume $inst"
  done
  echo ""
}

# ---------------------------------------------------------------------------
# base-update — trigger APK/resource update task
# ---------------------------------------------------------------------------
cmd_base_update() {
  require_cmd kubectl

  echo "Triggering base-update task..."
  kubectl -n "$NAMESPACE" delete redroidtask base-update 2>/dev/null || true
  sleep 2
  kubectl -n "$NAMESPACE" apply -k "$APP_DIR" 2>/dev/null \
    || echo "(Flux will reconcile shortly)"

  echo ""
  echo "Watch logs:"
  echo "  kubectl -n $NAMESPACE logs -l redroid.isning.moe/task=base-update -c update-script -f"
}

# ---------------------------------------------------------------------------
# wake-run — apply on-demand task (example/maa-wakeinstance-task.yaml)
# ---------------------------------------------------------------------------
cmd_wake_run() {
  local watch=false
  while [[ $# -gt 0 ]]; do
    case "$1" in --watch|-w) watch=true ;; esac
    shift
  done

  require_cmd kubectl
  local task_file="$EXAMPLE_DIR/maa-wakeinstance-task.yaml"
  [[ -f "$task_file" ]] || { echo "error: $task_file not found" >&2; exit 1; }

  # Delete previous run so the one-shot Job can be re-created
  if kubectl -n "$NAMESPACE" get redroidtask maa-wake-run &>/dev/null; then
    echo "Deleting previous maa-wake-run task..."
    kubectl -n "$NAMESPACE" delete redroidtask maa-wake-run
  fi

  echo "Applying maa-wakeinstance-task.yaml..."
  kubectl -n "$NAMESPACE" apply -f "$task_file"

  if $watch; then
    echo ""
    echo "Watching instance phase (Ctrl-C to stop):"
    echo "  expect: Stopped → Running → Stopped"
    echo ""
    kubectl -n "$NAMESPACE" get redroidinstances -w &
    local watch_pid=$!
    trap "kill $watch_pid 2>/dev/null; exit" INT TERM

    sleep 5
    echo ""
    echo "Following maa-cli logs..."
    kubectl -n "$NAMESPACE" logs -l redroid.isning.moe/task=maa-wake-run \
      -c maa-cli --follow --since=1m 2>/dev/null || true

    kill "$watch_pid" 2>/dev/null || true
  else
    echo ""
    echo "Task applied. Watch progress:"
    echo "  kubectl -n $NAMESPACE get redroidinstances -w"
    echo "  kubectl -n $NAMESPACE logs -l redroid.isning.moe/task=maa-wake-run -c maa-cli -f"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
cmd="${1:-}"
[[ -z "$cmd" ]] && usage

case "$cmd" in
  status)      cmd_status ;;
  base-init)   cmd_base_init ;;
  base-update) cmd_base_update ;;
  wake-run)    shift; cmd_wake_run "$@" ;;
  -h|--help)   usage ;;
  *)           echo "Unknown command: $cmd"; usage ;;
esac
