#!/usr/bin/env bash

parse_image_line() {
  local line="${1-}" platform="" source="" token
  local -a tokens
  read -r -a tokens <<< "$line"

  local i=0
  while ((i < ${#tokens[@]})); do
    token="${tokens[$i]}"
    case "$token" in
      --platform=*)
        platform="${token#--platform=}"
        ;;
      --platform)
        i=$((i + 1))
        ((i < ${#tokens[@]})) || {
          echo "missing value for --platform" >&2
          return 1
        }
        platform="${tokens[$i]}"
        ;;
      --*)
        echo "unsupported option: $token" >&2
        return 1
        ;;
      *)
        [[ -z "$source" ]] || {
          echo "multiple image references" >&2
          return 1
        }
        source="$token"
        ;;
    esac
    i=$((i + 1))
  done

  [[ -n "$source" ]] || {
    echo "missing image reference" >&2
    return 1
  }
  if [[ -n "$platform" ]]; then
    case "$platform" in
      */|/*|*//*)
        echo "invalid platform: $platform" >&2
        return 1
        ;;
    esac
    local platform_slashes="${platform//[^\/]/}"
    [[ "${#platform_slashes}" -eq 1 || "${#platform_slashes}" -eq 2 ]] || {
      echo "invalid platform: $platform" >&2
      return 1
    }
  fi

  local digest=""
  case "$source" in
    *@*)
      digest="${source##*@}"
      [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        echo "invalid digest: $digest" >&2
        return 1
      }
      ;;
  esac

  local without_digest="${source%%@*}"
  local last_segment="${without_digest##*/}"
  local image_path tag
  if [[ "$last_segment" == *:* ]]; then
    tag="${last_segment##*:}"
    image_path="${without_digest%:*}"
  else
    tag="latest"
    image_path="$without_digest"
  fi

  local first_segment="${image_path%%/*}"
  if [[ "$image_path" == */* ]] &&
     { [[ "$first_segment" == *.* ]] ||
       [[ "$first_segment" == *:* ]] ||
       [[ "$first_segment" == "localhost" ]]; }; then
    image_path="${image_path#*/}"
  fi

  [[ -n "$image_path" && -n "$tag" ]] || {
    echo "invalid image reference: $source" >&2
    return 1
  }

  if [[ -n "$digest" ]]; then
    tag="${tag}-sha256-${digest:7:12}"
  fi

  local target_repository="${image_path//\//_}"
  if [[ -n "$platform" ]]; then
    target_repository="${target_repository}_${platform//\//_}"
  fi

  printf '%s|%s|%s|%s\n' \
    "$platform" "$source" "$target_repository" "$tag"
}
