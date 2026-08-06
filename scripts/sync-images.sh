#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=image-name.sh
source "$script_dir/image-name.sh"

command -v skopeo >/dev/null 2>&1 || {
  echo "skopeo is required but was not found in PATH; install skopeo before running this script" >&2
  exit 1
}

input_file="${1:-images.txt}"
: "${ALIYUN_REGISTRY:?ALIYUN_REGISTRY is required}"
: "${ALIYUN_NAME_SPACE:?ALIYUN_NAME_SPACE is required}"
[[ -f "$input_file" ]] || {
  echo "image list not found: $input_file" >&2
  exit 1
}

# Seconds to wait before the single retry in fetch_source_digest_with_retry.
# Overridable so tests don't sleep; not meant as a general knob.
SKOPEO_RETRY_DELAY="${SKOPEO_RETRY_DELAY:-2}"

# fetch_config_digest is always invoked through a `$(...)` command
# substitution (to capture the digest on stdout), which runs it in a
# subshell — a plain variable assignment for the error reason would be
# lost once that subshell exits. Use a file on disk instead, which
# persists across the subshell boundary; callers read it right after a
# failed call via `$(<"$FETCH_CONFIG_DIGEST_ERROR_FILE")`.
FETCH_CONFIG_DIGEST_ERROR_FILE="$(mktemp)" || {
  echo "failed to create temp file for error reporting" >&2
  exit 1
}
trap 'rm -f "$FETCH_CONFIG_DIGEST_ERROR_FILE"' EXIT

# Hashes the config blob of image $1 as seen by Skopeo for the current
# platform (or the override args in $2+). Prints the sha256 hex digest and
# returns 0 on success; returns 1 if Skopeo cannot inspect the reference or
# returns an empty config blob (used to detect both "source unreachable"
# and "target does not exist"). On failure, writes the diagnostic reason to
# $FETCH_CONFIG_DIGEST_ERROR_FILE.
fetch_config_digest() {
  local ref="$1"
  shift
  local tmp tmp_err
  tmp="$(mktemp)" || return 1
  tmp_err="$(mktemp)" || {
    rm -f "$tmp"
    return 1
  }
  if ! skopeo "$@" inspect --raw --config "docker://$ref" >"$tmp" 2>"$tmp_err"; then
    tr '\n' ' ' <"$tmp_err" >"$FETCH_CONFIG_DIGEST_ERROR_FILE"
    rm -f "$tmp" "$tmp_err"
    return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    printf '%s' "skopeo returned an empty config blob for $ref" >"$FETCH_CONFIG_DIGEST_ERROR_FILE"
    rm -f "$tmp" "$tmp_err"
    return 1
  fi
  local digest
  digest="$(sha256_of_file "$tmp")" || {
    printf '%s' "failed to hash config blob for $ref" >"$FETCH_CONFIG_DIGEST_ERROR_FILE"
    rm -f "$tmp" "$tmp_err"
    return 1
  }
  rm -f "$tmp" "$tmp_err"
  printf '%s\n' "$digest"
}

# Wraps fetch_config_digest for the source image with one backoff retry.
# On the first failure, prints the specific reason and sleeps before
# retrying once; on final failure, $FETCH_CONFIG_DIGEST_ERROR_FILE holds
# the last attempt's reason for the caller to report.
fetch_source_digest_with_retry() {
  local ref="$1"
  shift
  local attempt=1
  local digest
  while :; do
    if digest="$(fetch_config_digest "$ref" "$@")"; then
      printf '%s\n' "$digest"
      return 0
    fi
    ((attempt >= 2)) && return 1
    echo "Warning: source inspect failed for $ref (attempt $attempt/2): $(<"$FETCH_CONFIG_DIGEST_ERROR_FILE"); retrying in ${SKOPEO_RETRY_DELAY}s" >&2
    sleep "$SKOPEO_RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "no sha256 utility found (need sha256sum or shasum)" >&2
    return 1
  fi
}

success=0
skipped=0
failed=0

while IFS= read -r line || [[ -n "$line" ]]; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

  if ! parsed="$(parse_image_line "$line")"; then
    failed=$((failed + 1))
    continue
  fi
  IFS='|' read -r platform source repository tag <<<"$parsed"
  target="$ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/$repository:$tag"

  override_args=()
  if [[ -n "$platform" ]]; then
    platform_os="${platform%%/*}"
    platform_rest="${platform#*/}"
    if [[ "$platform_rest" == */* ]]; then
      platform_arch="${platform_rest%%/*}"
      platform_variant="${platform_rest#*/}"
    else
      platform_arch="$platform_rest"
      platform_variant=""
    fi
    override_args=(--override-os "$platform_os" --override-arch "$platform_arch")
    [[ -n "$platform_variant" ]] && override_args+=(--override-variant "$platform_variant")
  fi

  if ! source_digest="$(fetch_source_digest_with_retry "$source" "${override_args[@]+"${override_args[@]}"}")"; then
    echo "Failed: source inspect $source: $(<"$FETCH_CONFIG_DIGEST_ERROR_FILE")" >&2
    failed=$((failed + 1))
    continue
  fi

  target_exists=1
  if target_digest="$(fetch_config_digest "$target" "${override_args[@]+"${override_args[@]}"}")"; then
    target_exists=0
  else
    echo "Note: target inspect failed for $target (treating as not existing): $(<"$FETCH_CONFIG_DIGEST_ERROR_FILE")" >&2
  fi

  if [[ "$target_exists" -eq 0 && "$source_digest" == "$target_digest" ]]; then
    echo "Skip unchanged: $target"
    skipped=$((skipped + 1))
    continue
  fi

  pull_args=(pull)
  [[ -n "$platform" ]] && pull_args+=(--platform "$platform")
  pull_args+=("$source")

  if docker "${pull_args[@]}" &&
    docker tag "$source" "$target" &&
    docker push "$target"; then
    echo "Synced: $source -> $target"
    success=$((success + 1))
  else
    echo "Failed: $source -> $target" >&2
    failed=$((failed + 1))
  fi

  docker image rm "$source" "$target" >/dev/null 2>&1 ||
    echo "Warning: image cleanup incomplete for $source" >&2
done <"$input_file"

echo "Sync summary: success=$success skipped=$skipped failed=$failed"
((failed == 0))
