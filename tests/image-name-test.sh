#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/image-name.sh
source "${SCRIPT_DIR}/../scripts/image-name.sh"

failures=0

assert_parse() {
  local input="$1"
  local expected="$2"
  local actual
  actual="$(parse_image_line "$input")" || {
    echo "FAIL: parse_image_line returned nonzero for valid input: $input" >&2
    failures=$((failures + 1))
    return
  }
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: parse_image_line" >&2
    echo "  input:    $input" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    failures=$((failures + 1))
  fi
}

assert_parse_under_set_e() {
  local input="$1"
  local expected="$2"
  local actual
  # Direct call under set -e — no || guard; ((i++)) bug exits shell otherwise.
  actual="$(parse_image_line "$input")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: parse_image_line under set -e" >&2
    echo "  input:    $input" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    failures=$((failures + 1))
  fi
}

assert_invalid() {
  local input="$1"
  local expected_stderr="${2:-}"
  local stderr_file
  stderr_file="$(mktemp)"
  if parse_image_line "$input" >/dev/null 2>"$stderr_file"; then
    echo "FAIL: expected invalid input to fail: ${input:-<empty>}" >&2
    failures=$((failures + 1))
  elif [[ -z "$(<"$stderr_file")" ]]; then
    echo "FAIL: expected stderr diagnostic for invalid input: ${input:-<empty>}" >&2
    failures=$((failures + 1))
  elif [[ -n "$expected_stderr" && "$(<"$stderr_file")" != "$expected_stderr" ]]; then
    echo "FAIL: unexpected stderr for invalid input: ${input:-<empty>}" >&2
    echo "  expected: $expected_stderr" >&2
    echo "  actual:   $(<"$stderr_file")" >&2
    failures=$((failures + 1))
  fi
  rm -f "$stderr_file"
}

assert_parse \
  "ghcr.io/immich-app/immich-server:release" \
  "|ghcr.io/immich-app/immich-server:release|immich-app_immich-server|release"
assert_parse \
  "--platform=linux/arm64 xiaoyaliu/alist" \
  "linux/arm64|xiaoyaliu/alist|xiaoyaliu_alist_linux_arm64|latest"
assert_parse \
  "--platform linux/amd64 quay.io/example/team/image:v1" \
  "linux/amd64|quay.io/example/team/image:v1|example_team_image_linux_amd64|v1"
assert_parse "nginx:latest" "|nginx:latest|nginx|latest"
assert_parse "registry.example.com:5000/team/image:2" \
  "|registry.example.com:5000/team/image:2|team_image|2"
assert_parse_under_set_e "nginx:latest" "|nginx:latest|nginx|latest"
assert_parse_under_set_e \
  "--platform linux/amd64 quay.io/example/team/image:v1" \
  "linux/amd64|quay.io/example/team/image:v1|example_team_image_linux_amd64|v1"

if grep -qE '\(\(i\+\+\)\)' "${SCRIPT_DIR}/../scripts/image-name.sh"; then
  echo "FAIL: scripts/image-name.sh uses unsafe ((i++)) increment" >&2
  failures=$((failures + 1))
fi

assert_invalid "" "missing image reference"
assert_invalid "--platform=linux/arm64" "missing image reference"
assert_invalid "--unknown value image:tag" "unsupported option: --unknown"

# Digest references: preserve full source for Docker, but derive a mutable
# target tag ("<tag>-sha256-<12 hex chars>") since a raw digest cannot be
# used as a tag and must not silently collapse to a shared "latest" name.
digest_hex="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
short_hex="0123456789ab"
assert_parse "foo/bar@sha256:${digest_hex}" \
  "|foo/bar@sha256:${digest_hex}|foo_bar|latest-sha256-${short_hex}"
assert_parse "foo/bar:v1@sha256:${digest_hex}" \
  "|foo/bar:v1@sha256:${digest_hex}|foo_bar|v1-sha256-${short_hex}"
assert_parse "ghcr.io/foo/bar:v1@sha256:${digest_hex}" \
  "|ghcr.io/foo/bar:v1@sha256:${digest_hex}|foo_bar|v1-sha256-${short_hex}"

assert_invalid "foo/bar@sha256:abc" "invalid digest: sha256:abc"
assert_invalid "foo/bar@sha512:${digest_hex}" "invalid digest: sha512:${digest_hex}"
assert_invalid "foo/bar@sha256:" "invalid digest: sha256:"

# Standard three-segment platform: os/arch/variant. The variant flattens
# into the target repository suffix just like the two-segment case.
assert_parse \
  "--platform linux/arm/v7 xiaoyaliu/alist" \
  "linux/arm/v7|xiaoyaliu/alist|xiaoyaliu_alist_linux_arm_v7|latest"
assert_parse \
  "--platform=linux/arm/v7 xiaoyaliu/alist" \
  "linux/arm/v7|xiaoyaliu/alist|xiaoyaliu_alist_linux_arm_v7|latest"

assert_invalid "--platform=linux/ xiaoyaliu/alist" "invalid platform: linux/"
assert_invalid "--platform=/amd64 xiaoyaliu/alist" "invalid platform: /amd64"
assert_invalid "--platform=linux/arm/v7/extra xiaoyaliu/alist" "invalid platform: linux/arm/v7/extra"
assert_invalid "--platform=linux xiaoyaliu/alist" "invalid platform: linux"

if ((failures > 0)); then
  echo "${failures} assertion(s) failed" >&2
  exit 1
fi

echo "All image-name parser tests passed"
