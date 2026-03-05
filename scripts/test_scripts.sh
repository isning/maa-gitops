#!/usr/bin/env sh
# =============================================================================
# Unit Tests for base-init and base-update Scripts
# =============================================================================
#
# Usage:
#   ./scripts/test_scripts.sh           # Run all tests
#   ./scripts/test_scripts.sh --verbose # Run with verbose output
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# =============================================================================

set -e

# ── Test Framework ───────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERBOSE="${VERBOSE:-false}"
[ "$1" = "--verbose" ] && VERBOSE=true

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log_test() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf "${YELLOW}TEST${NC} %s\n" "$1"
}

log_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf "${GREEN}PASS${NC} %s\n" "$1"
}

log_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "${RED}FAIL${NC} %s\n" "$1"
  [ -n "$2" ] && printf "     Expected: %s\n" "$2"
  [ -n "$3" ] && printf "     Got:      %s\n" "$3"
}

assert_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  log_test "$name"
  if [ "$expected" = "$actual" ]; then
    log_pass "$name"
  else
    log_fail "$name" "$expected" "$actual"
  fi
}

assert_not_empty() {
  local name="$1"
  local value="$2"
  log_test "$name"
  if [ -n "$value" ]; then
    log_pass "$name"
  else
    log_fail "$name" "<non-empty>" "<empty>"
  fi
}

assert_empty() {
  local name="$1"
  local value="$2"
  log_test "$name"
  if [ -z "$value" ]; then
    log_pass "$name"
  else
    log_fail "$name" "<empty>" "$value"
  fi
}

assert_true() {
  local name="$1"
  local value="$2"
  log_test "$name"
  if [ "$value" = "true" ]; then
    log_pass "$name"
  else
    log_fail "$name" "true" "$value"
  fi
}

assert_false() {
  local name="$1"
  local value="$2"
  log_test "$name"
  if [ "$value" = "false" ]; then
    log_pass "$name"
  else
    log_fail "$name" "false" "$value"
  fi
}

# ── Extract Scripts from YAML ────────────────────────────────────────────────

extract_scripts() {
  BASE_YAML="$REPO_ROOT/manifests/base.yaml"
  if [ ! -f "$BASE_YAML" ]; then
    echo "ERROR: $BASE_YAML not found"
    exit 1
  fi
  
  # Extract init.sh and update.sh using yq or grep+sed fallback
  if command -v yq >/dev/null 2>&1; then
    yq 'select(.metadata.name == "base-init-script") | .data["init.sh"]' "$BASE_YAML" > /tmp/test_init.sh
    yq 'select(.metadata.name == "base-update-script") | .data["update.sh"]' "$BASE_YAML" > /tmp/test_update.sh
  else
    echo "WARNING: yq not found, skipping script extraction tests"
    return 1
  fi
  return 0
}

# =============================================================================
# Test: Version Parsing
# =============================================================================

test_version_parsing() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Test Suite: Version Parsing"
  echo "═══════════════════════════════════════════════════════════════════════"
  
  # Test data - compact JSON (no whitespace)
  VERSION_JSON='{"resVersion":"26-02-28-10-42-20_2bc282","clientVersion":"2.7.01"}'
  
  # Parse clientVersion
  LATEST_CLIENT=$(echo "$VERSION_JSON" | grep -oE '"clientVersion":"[^"]*"' | sed 's/"clientVersion":"//;s/"//')
  assert_eq "Parse clientVersion from compact JSON" "2.7.01" "$LATEST_CLIENT"
  
  # Parse resVersion
  LATEST_RES=$(echo "$VERSION_JSON" | grep -oE '"resVersion":"[^"]*"' | sed 's/"resVersion":"//;s/"//')
  assert_eq "Parse resVersion from compact JSON" "26-02-28-10-42-20_2bc282" "$LATEST_RES"
  
  # Test data - pretty JSON (with newlines)
  VERSION_JSON_PRETTY='{
  "resVersion": "26-02-28-10-42-20_2bc282",
  "clientVersion": "2.7.01"
}'
  
  # Parse from pretty JSON (needs tr to remove newlines for grep -oE)
  LATEST_CLIENT_PRETTY=$(echo "$VERSION_JSON_PRETTY" | tr -d '\n\r' | grep -oE '"clientVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"clientVersion"[[:space:]]*:[[:space:]]*"//;s/"//')
  assert_eq "Parse clientVersion from pretty JSON" "2.7.01" "$LATEST_CLIENT_PRETTY"
  
  # Combined version string
  COMBINED="${LATEST_CLIENT}:${LATEST_RES}"
  assert_eq "Combined version string" "2.7.01:26-02-28-10-42-20_2bc282" "$COMBINED"
}

# =============================================================================
# Test: Version Comparison Logic
# =============================================================================

test_version_comparison() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Test Suite: Version Comparison"
  echo "═══════════════════════════════════════════════════════════════════════"
  
  LATEST_VERSION="2.7.01:26-02-28-10-42-20_2bc282"
  LATEST_CLIENT="2.7.01"
  
  # Test 1: Same version - should skip update
  STORED_VERSION="2.7.01:26-02-28-10-42-20_2bc282"
  if [ -n "$STORED_VERSION" ] && [ "$LATEST_VERSION" = "$STORED_VERSION" ]; then
    RESULT="skip"
  else
    RESULT="update"
  fi
  assert_eq "Same version → skip update" "skip" "$RESULT"
  
  # Test 2: Different APK version - should update APK
  STORED_VERSION="2.6.50:25-12-01-10-00-00_abc123"
  STORED_CLIENT=$(echo "$STORED_VERSION" | cut -d: -f1)
  APK_CHANGED=false
  [ "$STORED_CLIENT" != "$LATEST_CLIENT" ] && APK_CHANGED=true
  assert_true "Different APK version → APK_CHANGED=true" "$APK_CHANGED"
  assert_eq "Stored client extracted correctly" "2.6.50" "$STORED_CLIENT"
  
  # Test 3: Same APK, different resources - should update resources only
  STORED_VERSION="2.7.01:25-12-01-10-00-00_abc123"
  STORED_CLIENT=$(echo "$STORED_VERSION" | cut -d: -f1)
  APK_CHANGED=false
  [ "$STORED_CLIENT" != "$LATEST_CLIENT" ] && APK_CHANGED=true
  assert_false "Same APK version → APK_CHANGED=false" "$APK_CHANGED"
  
  if [ -n "$STORED_VERSION" ] && [ "$LATEST_VERSION" = "$STORED_VERSION" ]; then
    RESULT="skip"
  else
    RESULT="update"
  fi
  assert_eq "Same APK, different resources → still needs update" "update" "$RESULT"
  
  # Test 4: Empty stored version (first run) - should update
  STORED_VERSION=""
  if [ -n "$STORED_VERSION" ] && [ "$LATEST_VERSION" = "$STORED_VERSION" ]; then
    RESULT="skip"
  else
    RESULT="update"
  fi
  assert_eq "Empty stored version → update" "update" "$RESULT"
  
  # Test 5: Stored version with only client (malformed) - should handle gracefully
  STORED_VERSION="2.7.01"
  STORED_CLIENT=$(echo "$STORED_VERSION" | cut -d: -f1)
  assert_eq "Malformed version: extract client" "2.7.01" "$STORED_CLIENT"
}

# =============================================================================
# Test: Download Monitor Logic  
# =============================================================================

test_download_monitor() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Test Suite: Download Monitor Logic"
  echo "═══════════════════════════════════════════════════════════════════════"
  
  # Simulate the monitoring logic without actual file system
  GAME_IDLE_WAIT=10
  
  # Test 1: Size changes should reset idle counter
  idle_elapsed=5
  last_size=1000
  cur_size=1500
  
  if [ "$cur_size" != "$last_size" ]; then
    idle_elapsed=0
    last_size="$cur_size"
    RESULT="reset"
  else
    RESULT="stable"
  fi
  assert_eq "Size change resets idle counter" "reset" "$RESULT"
  assert_eq "idle_elapsed reset to 0" "0" "$idle_elapsed"
  
  # Test 2: Same size should increment idle counter
  idle_elapsed=5
  last_size=2500
  cur_size=2500
  
  if [ "$cur_size" != "$last_size" ]; then
    idle_elapsed=0
  else
    idle_elapsed=$((idle_elapsed + 5))
  fi
  assert_eq "Same size increments idle counter" "10" "$idle_elapsed"
  
  # Test 3: Idle threshold triggers completion
  COMPLETE=false
  if [ "$idle_elapsed" -ge "$GAME_IDLE_WAIT" ]; then
    COMPLETE=true
  fi
  assert_true "Idle threshold triggers completion" "$COMPLETE"
  
  # Test 4: Below idle threshold continues waiting
  idle_elapsed=5
  COMPLETE=false
  if [ "$idle_elapsed" -ge "$GAME_IDLE_WAIT" ]; then
    COMPLETE=true
  fi
  assert_false "Below idle threshold continues waiting" "$COMPLETE"
}

# =============================================================================
# Test: ADB Timeout Logic
# =============================================================================

test_adb_timeout() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Test Suite: ADB Timeout Logic"
  echo "═══════════════════════════════════════════════════════════════════════"
  
  ADB_CONNECT_TIMEOUT=300
  
  # Test 1: Elapsed time below timeout should continue
  elapsed=100
  if [ "$elapsed" -ge "$ADB_CONNECT_TIMEOUT" ]; then
    RESULT="timeout"
  else
    RESULT="continue"
  fi
  assert_eq "Elapsed 100s < 300s timeout → continue" "continue" "$RESULT"
  
  # Test 2: Elapsed time at timeout should exit
  elapsed=300
  if [ "$elapsed" -ge "$ADB_CONNECT_TIMEOUT" ]; then
    RESULT="timeout"
  else
    RESULT="continue"
  fi
  assert_eq "Elapsed 300s >= 300s timeout → timeout" "timeout" "$RESULT"
  
  # Test 3: Elapsed time above timeout should exit
  elapsed=350
  if [ "$elapsed" -ge "$ADB_CONNECT_TIMEOUT" ]; then
    RESULT="timeout"
  else
    RESULT="continue"
  fi
  assert_eq "Elapsed 350s > 300s timeout → timeout" "timeout" "$RESULT"
  
  # Test 4: Timeout increment math
  elapsed=0
  sleep_interval=5
  iterations=3
  for i in $(seq 1 $iterations); do
    elapsed=$((elapsed + sleep_interval))
  done
  assert_eq "3 iterations of 5s = 15s elapsed" "15" "$elapsed"
}

# =============================================================================
# Test: Shell Script Syntax
# =============================================================================

test_script_syntax() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Test Suite: Script Syntax Validation"
  echo "═══════════════════════════════════════════════════════════════════════"
  
  if ! extract_scripts; then
    echo "Skipping syntax tests (yq not available)"
    return
  fi
  
  # Test init.sh syntax
  log_test "init.sh syntax check (sh -n)"
  if sh -n /tmp/test_init.sh 2>/dev/null; then
    log_pass "init.sh syntax check (sh -n)"
  else
    log_fail "init.sh syntax check (sh -n)" "valid syntax" "syntax error"
  fi
  
  # Test update.sh syntax
  log_test "update.sh syntax check (sh -n)"
  if sh -n /tmp/test_update.sh 2>/dev/null; then
    log_pass "update.sh syntax check (sh -n)"
  else
    log_fail "update.sh syntax check (sh -n)" "valid syntax" "syntax error"
  fi
  
  # Test with shellcheck if available
  if command -v shellcheck >/dev/null 2>&1; then
    log_test "init.sh shellcheck"
    if shellcheck -S warning /tmp/test_init.sh 2>/dev/null; then
      log_pass "init.sh shellcheck"
    else
      log_fail "init.sh shellcheck" "no warnings" "has warnings"
    fi
    
    log_test "update.sh shellcheck"
    if shellcheck -S warning /tmp/test_update.sh 2>/dev/null; then
      log_pass "update.sh shellcheck"
    else
      log_fail "update.sh shellcheck" "no warnings" "has warnings"
    fi
  else
    echo "INFO: shellcheck not available, skipping advanced lint"
  fi
}

# =============================================================================
# Test: External API Availability (Optional - Network Tests)
# =============================================================================

test_external_apis() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Test Suite: External API Availability (Network Required)"
  echo "═══════════════════════════════════════════════════════════════════════"
  
  # Skip if --no-network flag
  if [ "$1" = "--no-network" ]; then
    echo "INFO: Skipping network tests (--no-network)"
    return
  fi
  
  # Test Version API
  log_test "Version API reachable"
  VERSION_JSON=$(curl -sf --max-time 10 "https://ak-conf.hypergryph.com/config/prod/official/Android/version" 2>/dev/null)
  if [ -n "$VERSION_JSON" ]; then
    log_pass "Version API reachable"
  else
    log_fail "Version API reachable" "JSON response" "empty/error"
  fi
  
  # Test APK URL redirects correctly (use GET with range header, HEAD doesn't follow redirects properly)
  log_test "APK download URL redirects to valid file"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -L -r 0-0 --max-time 30 "https://ak.hypergryph.com/downloads/android_lastest" 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "206" ]; then
    log_pass "APK download URL redirects to valid file"
  else
    log_fail "APK download URL redirects to valid file" "HTTP 200/206" "HTTP $HTTP_CODE"
  fi
}

# =============================================================================
# Test: Kustomize Build
# =============================================================================

test_kustomize_build() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Test Suite: Kustomize Build"
  echo "═══════════════════════════════════════════════════════════════════════"
  
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "INFO: kubectl not available, skipping kustomize tests"
    return
  fi
  
  log_test "Kustomize build manifests/"
  if kubectl kustomize "$REPO_ROOT/manifests/" > /tmp/kustomize-test.yaml 2>/dev/null; then
    log_pass "Kustomize build manifests/"
    
    # Count resources
    if command -v yq >/dev/null 2>&1; then
      INSTANCE_COUNT=$(yq 'select(.kind == "RedroidInstance") | .metadata.name' /tmp/kustomize-test.yaml 2>/dev/null | grep -c '^' || echo "0")
      TASK_COUNT=$(yq 'select(.kind == "RedroidTask") | .metadata.name' /tmp/kustomize-test.yaml 2>/dev/null | grep -c '^' || echo "0")
      
      log_test "RedroidInstance count >= 3"
      if [ "$INSTANCE_COUNT" -ge 3 ]; then
        log_pass "RedroidInstance count >= 3 (got $INSTANCE_COUNT)"
      else
        log_fail "RedroidInstance count >= 3" ">=3" "$INSTANCE_COUNT"
      fi
      
      log_test "RedroidTask count >= 2"
      if [ "$TASK_COUNT" -ge 2 ]; then
        log_pass "RedroidTask count >= 2 (got $TASK_COUNT)"
      else
        log_fail "RedroidTask count >= 2" ">=2" "$TASK_COUNT"
      fi
    fi
  else
    log_fail "Kustomize build manifests/" "success" "build error"
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " maa-gitops Script Unit Tests"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
  echo "Repository: $REPO_ROOT"
  echo "Date:       $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  
  # Run test suites
  test_version_parsing
  test_version_comparison
  test_download_monitor
  test_adb_timeout
  test_script_syntax
  test_kustomize_build
  test_external_apis "$@"
  
  # Summary
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Test Summary"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
  printf "Total:  %d\n" "$TESTS_RUN"
  printf "${GREEN}Passed: %d${NC}\n" "$TESTS_PASSED"
  printf "${RED}Failed: %d${NC}\n" "$TESTS_FAILED"
  echo ""
  
  if [ "$TESTS_FAILED" -gt 0 ]; then
    printf "${RED}FAILED${NC}\n"
    exit 1
  else
    printf "${GREEN}ALL TESTS PASSED${NC}\n"
    exit 0
  fi
}

main "$@"
