#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/../scripts/sync-images.sh"

if [[ ! -f "$SYNC_SCRIPT" ]]; then
  echo "FAIL: scripts/sync-images.sh does not exist" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"

# Fake skopeo only ever needs to answer `[global overrides] inspect --raw
# --config docker://<ref>`. Behavior is controlled by:
#   FAKE_INSPECT_FAIL_REFS       - newline list of refs that always fail
#                                   inspect (with a distinct stderr reason).
#   FAKE_INSPECT_FAIL_ONCE_REFS  - newline list of refs that fail inspect on
#                                   their first invocation only (marker file
#                                   under FAKE_ATTEMPT_DIR), then succeed.
#   FAKE_CONFIG_OVERRIDES        - newline list of "ref=content" pairs; refs
#                                   not listed default to "config-for-<ref>"
#                                   so any two distinct refs naturally hash
#                                   differently.
cat >"$fake_bin/skopeo" <<'EOF'
#!/usr/bin/env bash
printf 'skopeo' >>"$FAKE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$FAKE_COMMAND_LOG"
printf '\n' >>"$FAKE_COMMAND_LOG"

ref=""
for arg in "$@"; do
  case "$arg" in
    docker://*) ref="${arg#docker://}" ;;
  esac
done

case "
${FAKE_INSPECT_FAIL_ONCE_REFS-}
" in
  *"
$ref
"*)
    marker="$FAKE_ATTEMPT_DIR/$(printf '%s' "$ref" | tr -c 'A-Za-z0-9' '_')"
    if [[ ! -e "$marker" ]]; then
      : >"$marker"
      echo "fake transient inspect error for $ref" >&2
      exit 1
    fi
    ;;
esac

case "
${FAKE_INSPECT_FAIL_REFS-}
" in
  *"
$ref
"*)
    echo "fake permanent inspect error for $ref" >&2
    exit 1
    ;;
esac

content="config-for-$ref"
if [[ -n "${FAKE_CONFIG_OVERRIDES-}" ]]; then
  while IFS='=' read -r o_ref o_content; do
    [[ -z "$o_ref" ]] && continue
    [[ "$o_ref" == "$ref" ]] && content="$o_content"
  done <<<"$FAKE_CONFIG_OVERRIDES"
fi

printf '%s' "$content"
exit 0
EOF

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker' >>"$FAKE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$FAKE_COMMAND_LOG"
printf '\n' >>"$FAKE_COMMAND_LOG"

if [[ "${1-}" == "push" ]]; then
  case "
${FAKE_FAIL_PUSH_IMAGES-}
" in
    *"
${2-}
"*) exit 1 ;;
  esac
fi
exit 0
EOF
chmod +x "$fake_bin/skopeo" "$fake_bin/docker"

failures=0

run_case() {
  local name="$1"
  local fixture_content="$2"
  local inspect_fail_refs="$3"
  local inspect_fail_once_refs="$4"
  local config_overrides="$5"
  local fail_push_images="$6"
  local expected_status="$7"
  local expected_log="$8"
  local expected_summary="$9"
  local expected_output_substrings="${10-}"
  local fixture="$tmp_dir/$name-images.txt"
  local command_log="$tmp_dir/$name-commands.log"
  local attempt_dir="$tmp_dir/$name-attempts"
  local output status actual_log

  printf '%s' "$fixture_content" >"$fixture"
  : >"$command_log"
  mkdir -p "$attempt_dir"

  output="$(
    PATH="$fake_bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_INSPECT_FAIL_REFS="$inspect_fail_refs" \
    FAKE_INSPECT_FAIL_ONCE_REFS="$inspect_fail_once_refs" \
    FAKE_ATTEMPT_DIR="$attempt_dir" \
    FAKE_CONFIG_OVERRIDES="$config_overrides" \
    FAKE_FAIL_PUSH_IMAGES="$fail_push_images" \
    ALIYUN_REGISTRY=registry.example.com \
    ALIYUN_NAME_SPACE=mirror \
    SKOPEO_RETRY_DELAY=0 \
      bash "$SYNC_SCRIPT" "$fixture" 2>&1
  )"
  status=$?
  actual_log="$(<"$command_log")"

  if [[ "$status" -ne "$expected_status" ]]; then
    echo "FAIL: $name exit status: expected $expected_status, got $status" >&2
    failures=$((failures + 1))
  fi
  if [[ "$actual_log" != "$expected_log" ]]; then
    echo "FAIL: $name command log mismatch" >&2
    echo "expected:" >&2
    printf '%s\n' "$expected_log" >&2
    echo "actual:" >&2
    printf '%s\n' "$actual_log" >&2
    failures=$((failures + 1))
  fi
  if [[ "$output" != *"$expected_summary"* ]]; then
    echo "FAIL: $name missing summary: $expected_summary" >&2
    echo "actual output: $output" >&2
    failures=$((failures + 1))
  fi
  if [[ -n "$expected_output_substrings" ]]; then
    while IFS= read -r substr; do
      [[ -z "$substr" ]] && continue
      if [[ "$output" != *"$substr"* ]]; then
        echo "FAIL: $name missing output substring: $substr" >&2
        echo "actual output: $output" >&2
        failures=$((failures + 1))
      fi
    done <<<"$expected_output_substrings"
  fi
}

# Same config digest on source and target -> skip, no docker calls.
run_case \
  "same-config-digest" \
  $'nginx:latest\n' \
  "" \
  "" \
  $'nginx:latest=SAME\nregistry.example.com/mirror/nginx:latest=SAME' \
  "" \
  0 \
  $'skopeo <inspect> <--raw> <--config> <docker://nginx:latest>\nskopeo <inspect> <--raw> <--config> <docker://registry.example.com/mirror/nginx:latest>' \
  "Sync summary: success=0 skipped=1 failed=0"

# Both inspects succeed but config digests differ -> sync runs.
run_case \
  "different-config-digest" \
  $'busybox:1.36\n' \
  "" \
  "" \
  "" \
  "" \
  0 \
  $'skopeo <inspect> <--raw> <--config> <docker://busybox:1.36>\nskopeo <inspect> <--raw> <--config> <docker://registry.example.com/mirror/busybox:1.36>\ndocker <pull> <busybox:1.36>\ndocker <tag> <busybox:1.36> <registry.example.com/mirror/busybox:1.36>\ndocker <push> <registry.example.com/mirror/busybox:1.36>\ndocker <image> <rm> <busybox:1.36> <registry.example.com/mirror/busybox:1.36>' \
  "Sync summary: success=1 skipped=0 failed=0"

# Target inspect fails (target does not exist) -> sync runs, and a
# diagnosable hint (with the fake's specific reason) is printed.
run_case \
  "missing-target" \
  $'redis:7\n' \
  "registry.example.com/mirror/redis:7" \
  "" \
  "" \
  "" \
  0 \
  $'skopeo <inspect> <--raw> <--config> <docker://redis:7>\nskopeo <inspect> <--raw> <--config> <docker://registry.example.com/mirror/redis:7>\ndocker <pull> <redis:7>\ndocker <tag> <redis:7> <registry.example.com/mirror/redis:7>\ndocker <push> <registry.example.com/mirror/redis:7>\ndocker <image> <rm> <redis:7> <registry.example.com/mirror/redis:7>' \
  "Sync summary: success=1 skipped=0 failed=0" \
  $'target inspect\nfake permanent inspect error for registry.example.com/mirror/redis:7'

# Source inspect fails on attempt 1, succeeds on retry (attempt 2) -> no
# failure recorded, comparison/sync proceeds normally. Retry warning
# includes the fake's specific first-attempt error.
run_case \
  "source-inspect-retry-succeeds" \
  $'flaky-source:1\n' \
  "" \
  "flaky-source:1" \
  "" \
  "" \
  0 \
  $'skopeo <inspect> <--raw> <--config> <docker://flaky-source:1>\nskopeo <inspect> <--raw> <--config> <docker://flaky-source:1>\nskopeo <inspect> <--raw> <--config> <docker://registry.example.com/mirror/flaky-source:1>\ndocker <pull> <flaky-source:1>\ndocker <tag> <flaky-source:1> <registry.example.com/mirror/flaky-source:1>\ndocker <push> <registry.example.com/mirror/flaky-source:1>\ndocker <image> <rm> <flaky-source:1> <registry.example.com/mirror/flaky-source:1>' \
  "Sync summary: success=1 skipped=0 failed=0" \
  "fake transient inspect error for flaky-source:1"

# Source inspect fails twice (initial + one retry) -> recorded as failure
# with the fake's specific final reason, no target inspect, continues to
# the next image.
run_case \
  "source-inspect-fails-continues" \
  $'bad-source:1\ngood-image:2\n' \
  "bad-source:1" \
  "" \
  "" \
  "" \
  1 \
  $'skopeo <inspect> <--raw> <--config> <docker://bad-source:1>\nskopeo <inspect> <--raw> <--config> <docker://bad-source:1>\nskopeo <inspect> <--raw> <--config> <docker://good-image:2>\nskopeo <inspect> <--raw> <--config> <docker://registry.example.com/mirror/good-image:2>\ndocker <pull> <good-image:2>\ndocker <tag> <good-image:2> <registry.example.com/mirror/good-image:2>\ndocker <push> <registry.example.com/mirror/good-image:2>\ndocker <image> <rm> <good-image:2> <registry.example.com/mirror/good-image:2>' \
  "Sync summary: success=1 skipped=0 failed=1" \
  "fake permanent inspect error for bad-source:1"

# Platform input (2-segment): override args precede inspect for both source
# and target, and pull receives --platform linux/arm64.
run_case \
  "platform" \
  $'--platform linux/arm64 xiaoyaliu/alist\n' \
  "" \
  "" \
  "" \
  "" \
  0 \
  $'skopeo <--override-os> <linux> <--override-arch> <arm64> <inspect> <--raw> <--config> <docker://xiaoyaliu/alist>\nskopeo <--override-os> <linux> <--override-arch> <arm64> <inspect> <--raw> <--config> <docker://registry.example.com/mirror/xiaoyaliu_alist_linux_arm64:latest>\ndocker <pull> <--platform> <linux/arm64> <xiaoyaliu/alist>\ndocker <tag> <xiaoyaliu/alist> <registry.example.com/mirror/xiaoyaliu_alist_linux_arm64:latest>\ndocker <push> <registry.example.com/mirror/xiaoyaliu_alist_linux_arm64:latest>\ndocker <image> <rm> <xiaoyaliu/alist> <registry.example.com/mirror/xiaoyaliu_alist_linux_arm64:latest>' \
  "Sync summary: success=1 skipped=0 failed=0"

# Platform input (3-segment, with variant): --override-variant appended
# after --override-arch, still before `inspect`; target suffix flattens
# all three segments.
run_case \
  "platform-variant" \
  $'--platform linux/arm/v7 xiaoyaliu/alist\n' \
  "" \
  "" \
  "" \
  "" \
  0 \
  $'skopeo <--override-os> <linux> <--override-arch> <arm> <--override-variant> <v7> <inspect> <--raw> <--config> <docker://xiaoyaliu/alist>\nskopeo <--override-os> <linux> <--override-arch> <arm> <--override-variant> <v7> <inspect> <--raw> <--config> <docker://registry.example.com/mirror/xiaoyaliu_alist_linux_arm_v7:latest>\ndocker <pull> <--platform> <linux/arm/v7> <xiaoyaliu/alist>\ndocker <tag> <xiaoyaliu/alist> <registry.example.com/mirror/xiaoyaliu_alist_linux_arm_v7:latest>\ndocker <push> <registry.example.com/mirror/xiaoyaliu_alist_linux_arm_v7:latest>\ndocker <image> <rm> <xiaoyaliu/alist> <registry.example.com/mirror/xiaoyaliu_alist_linux_arm_v7:latest>' \
  "Sync summary: success=1 skipped=0 failed=0"

# One failed push: next image still runs; final exit is 1 and failed=1.
run_case \
  "failed-push-continues" \
  $'alpine:3.20\nredis:7\n' \
  "" \
  "" \
  "" \
  "registry.example.com/mirror/alpine:3.20" \
  1 \
  $'skopeo <inspect> <--raw> <--config> <docker://alpine:3.20>\nskopeo <inspect> <--raw> <--config> <docker://registry.example.com/mirror/alpine:3.20>\ndocker <pull> <alpine:3.20>\ndocker <tag> <alpine:3.20> <registry.example.com/mirror/alpine:3.20>\ndocker <push> <registry.example.com/mirror/alpine:3.20>\ndocker <image> <rm> <alpine:3.20> <registry.example.com/mirror/alpine:3.20>\nskopeo <inspect> <--raw> <--config> <docker://redis:7>\nskopeo <inspect> <--raw> <--config> <docker://registry.example.com/mirror/redis:7>\ndocker <pull> <redis:7>\ndocker <tag> <redis:7> <registry.example.com/mirror/redis:7>\ndocker <push> <registry.example.com/mirror/redis:7>\ndocker <image> <rm> <redis:7> <registry.example.com/mirror/redis:7>' \
  "Sync summary: success=1 skipped=0 failed=1"

# Blank lines and whitespace-prefixed comments invoke no commands.
run_case \
  "ignored-lines" \
  $'\n   \n# comment\n   # indented comment\n' \
  "" \
  "" \
  "" \
  "" \
  0 \
  "" \
  "Sync summary: success=0 skipped=0 failed=0"

# Missing skopeo: fail fast, explicit error, no docker invocation at all.
no_skopeo_bin="$tmp_dir/no-skopeo-bin"
mkdir -p "$no_skopeo_bin"
cp "$fake_bin/docker" "$no_skopeo_bin/docker"
chmod +x "$no_skopeo_bin/docker"

no_skopeo_fixture="$tmp_dir/no-skopeo-images.txt"
printf 'nginx:latest\n' >"$no_skopeo_fixture"
no_skopeo_log="$tmp_dir/no-skopeo-commands.log"
: >"$no_skopeo_log"

no_skopeo_output="$(
  PATH="$no_skopeo_bin:/usr/bin:/bin" \
  FAKE_COMMAND_LOG="$no_skopeo_log" \
  ALIYUN_REGISTRY=registry.example.com \
  ALIYUN_NAME_SPACE=mirror \
    bash "$SYNC_SCRIPT" "$no_skopeo_fixture" 2>&1
)"
no_skopeo_status=$?
no_skopeo_log_content="$(<"$no_skopeo_log")"

if [[ "$no_skopeo_status" -eq 0 ]]; then
  echo "FAIL: no-skopeo: expected nonzero exit status, got 0" >&2
  failures=$((failures + 1))
fi
if [[ -n "$no_skopeo_log_content" ]]; then
  echo "FAIL: no-skopeo: expected no docker/skopeo invocations, got: $no_skopeo_log_content" >&2
  failures=$((failures + 1))
fi
if [[ "$no_skopeo_output" != *"skopeo"* ]]; then
  echo "FAIL: no-skopeo: expected error message mentioning skopeo, got: $no_skopeo_output" >&2
  failures=$((failures + 1))
fi

workflow="${SCRIPT_DIR}/../.github/workflows/docker.yaml"
if [[ -n "${WORKFLOW_CONTENT-}" ]]; then
  workflow="$tmp_dir/workflow.yaml"
  printf '%s' "$WORKFLOW_CONTENT" >"$workflow"
fi

logical_workflow="$tmp_dir/workflow-logical.yaml"
awk '
  /\\[[:space:]]*$/ {
    sub(/\\[[:space:]]*$/, "")
    printf "%s ", $0
    next
  }
  { print }
' "$workflow" >"$logical_workflow"
workflow="$logical_workflow"

for expected in \
  "password-stdin" \
  "bash scripts/sync-images.sh images.txt" \
  "- 'images.txt'"
do
  if ! grep -q -- "$expected" "$workflow"; then
    echo "FAIL: workflow missing: $expected" >&2
    failures=$((failures + 1))
  fi
done

while IFS='|' read -r description pattern; do
  if grep -Ev '^[[:space:]]*#' "$workflow" | grep -Eq -- "$pattern"; then
    echo "FAIL: workflow contains forbidden $description" >&2
    failures=$((failures + 1))
  fi
done <<'EOF'
plaintext docker login password|docker[[:space:]]+login.*([[:space:]]-p([^[:space:]]*)?([[:space:]]|$)|[[:space:]]--password(=|[[:space:]]|$))
inline duplicate-image parser|declare[[:space:]]+-A[[:space:]]+(duplicate_images|temp_map)
inline images.txt reader|done[[:space:]]*<[[:space:]]*images\.txt
inline image pull|docker[[:space:]]+pull[[:space:]]+["]?\$line
inline target-name construction|new_image=
EOF

# Structural workflow checks: minimal-scope secrets, pinned third-party
# action, and top-level `permissions`. Uses the original (non-flattened)
# workflow file so YAML structure stays intact for the Ruby YAML parser.
original_workflow="${SCRIPT_DIR}/../.github/workflows/docker.yaml"
if [[ -n "${WORKFLOW_CONTENT-}" ]]; then
  original_workflow="$tmp_dir/workflow.yaml"
fi

workflow_check_script="$tmp_dir/workflow_check.rb"
cat >"$workflow_check_script" <<'RUBY'
require 'yaml'

path = ARGV[0]
doc = YAML.load_file(path)
failures = []

failures << "top-level env must not exist (secrets minimal scope)" if doc.key?('env')

jobs = doc['jobs'] || {}
jobs.each do |job_name, job|
  failures << "job '#{job_name}' must not declare top-level env" if job.key?('env')
end

permissions = doc['permissions']
unless permissions == { 'contents' => 'read' }
  failures << "top-level permissions must be {contents: read}, got: #{permissions.inspect}"
end

steps = (jobs['build'] || {})['steps'] || []

login_step = steps.find { |s| (s['run'] || '').include?('docker login') }
sync_step = steps.find { |s| (s['run'] || '').include?('sync-images.sh') }

failures << "could not find login step" unless login_step
failures << "could not find sync step" unless sync_step

if login_step
  expected = %w[ALIYUN_REGISTRY ALIYUN_REGISTRY_USER ALIYUN_REGISTRY_PASSWORD].sort
  actual = (login_step['env'] || {}).keys.sort
  failures << "login step env must be exactly #{expected}, got #{actual}" unless actual == expected
end

if sync_step
  expected = %w[ALIYUN_REGISTRY ALIYUN_NAME_SPACE].sort
  actual = (sync_step['env'] || {}).keys.sort
  failures << "sync step env must be exactly #{expected}, got #{actual}" unless actual == expected
end

steps.each do |step|
  next if step.equal?(login_step)
  serialized = step.to_s
  %w[ALIYUN_REGISTRY_PASSWORD ALIYUN_REGISTRY_USER].each do |secret|
    if serialized.include?(secret)
      failures << "secret #{secret} must not appear outside the login step (found in step '#{step['name']}')"
    end
  end
end

steps.each do |step|
  uses = step['uses']
  next unless uses
  failures << "step '#{step['name']}' pins action to @master: #{uses}" if uses.end_with?('@master')
end

maximize_step = steps.find { |s| (s['uses'] || '').include?('maximize-build-space') }
expected_pin = 'easimon/maximize-build-space@c28619d8999a147d5e09c1199f84ff6af6ad5794'
if maximize_step
  failures << "maximize-build-space must be pinned to #{expected_pin}, got #{maximize_step['uses']}" if maximize_step['uses'] != expected_pin
else
  failures << "could not find maximize-build-space step"
end

if failures.empty?
  puts "workflow structural checks passed"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
RUBY

if ! workflow_check_output="$(ruby "$workflow_check_script" "$original_workflow" 2>&1)"; then
  echo "$workflow_check_output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  echo "$failures assertion(s) failed" >&2
  exit 1
fi

echo "All sync-images tests passed"
