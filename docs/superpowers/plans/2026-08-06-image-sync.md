# Image Sync Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement stable flattened image naming, platform suffixes, incremental ACR synchronization, and reliable failure reporting.

**Architecture:** Keep GitHub Actions responsible for runner setup and authentication. Move image parsing/naming into a pure sourceable Bash module and synchronization into a separate Bash script so naming behavior can be tested without Docker or network access.

**Tech Stack:** GitHub Actions YAML, Bash 4+, Docker CLI, Skopeo

## Global Constraints

- Remove source registry only when the first path segment contains `.`, contains `:`, or equals `localhost`.
- Flatten every remaining repository path by replacing `/` with `_`.
- Keep official single-segment names unchanged; never add `library_`.
- Append normalized platform as `_<os>_<arch>` after repository name.
- Preserve source digest for Docker operations; derive target tag from explicit tag or use `latest`, appending `-sha256-<12 hex>` when the source reference includes a digest.
- Skip a sync only when the source and target config blob digests match (checked via `skopeo inspect --config`); refresh mutable tags automatically otherwise.
- Continue after per-image failures, then exit nonzero when any image failed.
- Do not add management UI, Webhook, schedule, or dependencies.
- Do not create Git commits unless user explicitly requests them.

---

### Task 1: Testable image-line parser and naming

**Files:**
- Create: `tests/image-name-test.sh`
- Create: `scripts/image-name.sh`

**Interfaces:**
- Produces: `parse_image_line LINE`, which writes four `|`-separated fields: `platform`, `source_image`, `target_repository`, `target_tag`.
- Returns: `0` for valid input; nonzero with a diagnostic on stderr for invalid input.

- [ ] **Step 1: Write the failing parser test**

Create an assertion helper that calls `parse_image_line` and compares its exact `|`-separated output. Include these cases:

```bash
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
assert_parse "localhost/team/image@sha256:<64-hex>" \
  "|localhost/team/image@sha256:<64-hex>|team_image|latest-sha256-<first-12-hex>"
assert_invalid ""
assert_invalid "--platform=linux/arm64"
assert_invalid "--unknown value image:tag"
```

- [ ] **Step 2: Run test and verify RED**

Run: `bash tests/image-name-test.sh`

Expected: FAIL because `scripts/image-name.sh` does not exist.

- [ ] **Step 3: Implement minimal parser**

Create `scripts/image-name.sh` with:

```bash
parse_image_line() {
  local line="${1-}" platform="" source="" token
  local -a tokens
  read -r -a tokens <<< "$line"

  local i=0
  while ((i < ${#tokens[@]})); do
    token="${tokens[$i]}"
    case "$token" in
      --platform=*) platform="${token#--platform=}" ;;
      --platform)
        ((i++))
        ((i < ${#tokens[@]})) || {
          echo "missing value for --platform" >&2
          return 1
        }
        platform="${tokens[$i]}"
        ;;
      --*) echo "unsupported option: $token" >&2; return 1 ;;
      *)
        [[ -z "$source" ]] || {
          echo "multiple image references" >&2
          return 1
        }
        source="$token"
        ;;
    esac
    ((i++))
  done

  [[ -n "$source" ]] || {
    echo "missing image reference" >&2
    return 1
  }
  [[ -z "$platform" || "$platform" == */* ]] || {
    echo "invalid platform: $platform" >&2
    return 1
  }

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

  local target_repository="${image_path//\//_}"
  if [[ -n "$platform" ]]; then
    target_repository="${target_repository}_${platform//\//_}"
  fi

  printf '%s|%s|%s|%s\n' \
    "$platform" "$source" "$target_repository" "$tag"
}
```

- [ ] **Step 4: Run parser test and verify GREEN**

Run: `bash tests/image-name-test.sh`

Expected: all parser assertions pass and process exits `0`.

---

### Task 2: Incremental synchronization and failure aggregation

**Files:**
- Create: `tests/sync-images-test.sh`
- Create: `scripts/sync-images.sh`

**Interfaces:**
- Consumes: `parse_image_line LINE` from `scripts/image-name.sh`.
- Consumes environment: `ALIYUN_REGISTRY`, `ALIYUN_NAME_SPACE`.
- Consumes optional positional argument: image-list path, default `images.txt`.
- Produces: summary line `Sync summary: success=N skipped=N failed=N`.
- Returns: `0` when no failures occurred, otherwise `1`.

- [ ] **Step 1: Write failing synchronization tests**

Build temporary fake `docker` and `skopeo` executables that append arguments to a log. Test:

```bash
# Existing target: only skopeo inspect is recorded, result is skipped.
# Missing target: pull, tag, push, and cleanup are recorded in order.
# Platform input: pull receives --platform linux/arm64.
# One failed push: next image still runs; final exit is 1 and failed=1.
# Blank lines and whitespace-prefixed comments invoke no commands.
```

Set fake command behavior through `FAKE_EXISTING_IMAGES` and `FAKE_FAIL_PUSH_IMAGES`, prepend the fake directory to `PATH`, and invoke:

```bash
ALIYUN_REGISTRY=registry.example.com \
ALIYUN_NAME_SPACE=mirror \
bash scripts/sync-images.sh "$fixture"
```

- [ ] **Step 2: Run synchronization tests and verify RED**

Run: `bash tests/sync-images-test.sh`

Expected: FAIL because `scripts/sync-images.sh` does not exist.

- [ ] **Step 3: Implement synchronization loop**

Implement `scripts/sync-images.sh` with this flow:

```bash
#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/image-name.sh"

input_file="${1:-images.txt}"
: "${ALIYUN_REGISTRY:?ALIYUN_REGISTRY is required}"
: "${ALIYUN_NAME_SPACE:?ALIYUN_NAME_SPACE is required}"
[[ -f "$input_file" ]] || {
  echo "image list not found: $input_file" >&2
  exit 1
}

success=0
skipped=0
failed=0

while IFS= read -r line || [[ -n "$line" ]]; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

  if ! parsed="$(parse_image_line "$line")"; then
    ((failed++))
    continue
  fi
  IFS='|' read -r platform source repository tag <<< "$parsed"
  target="$ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/$repository:$tag"

  if skopeo inspect "docker://$target" >/dev/null 2>&1; then
    echo "Skip existing: $target"
    ((skipped++))
    continue
  fi

  pull_args=(pull)
  [[ -n "$platform" ]] && pull_args+=(--platform "$platform")
  pull_args+=("$source")

  if docker "${pull_args[@]}" &&
     docker tag "$source" "$target" &&
     docker push "$target"; then
    echo "Synced: $source -> $target"
    ((success++))
  else
    echo "Failed: $source -> $target" >&2
    ((failed++))
  fi

  docker image rm "$source" "$target" >/dev/null 2>&1 ||
    echo "Warning: image cleanup incomplete for $source" >&2
done < "$input_file"

echo "Sync summary: success=$success skipped=$skipped failed=$failed"
((failed == 0))
```

- [ ] **Step 4: Run synchronization tests and verify GREEN**

Run: `bash tests/sync-images-test.sh`

Expected: all fake-command scenarios pass, including continued processing and final nonzero status after a simulated failure.

---

### Task 3: Workflow integration and user documentation

**Files:**
- Modify: `.github/workflows/docker.yaml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `scripts/sync-images.sh images.txt`.
- GitHub trigger: manual, or push to `main` changing `images.txt`, `scripts/**`, or workflow file.

- [ ] **Step 1: Add static workflow assertions**

Extend `tests/sync-images-test.sh` to assert:

```bash
grep -q "password-stdin" .github/workflows/docker.yaml
grep -q "bash scripts/sync-images.sh images.txt" .github/workflows/docker.yaml
grep -q -- "- 'images.txt'" .github/workflows/docker.yaml
```

Run: `bash tests/sync-images-test.sh`

Expected: FAIL because workflow still contains inline synchronization and insecure `docker login -p`.

- [ ] **Step 2: Replace inline workflow logic**

Keep checkout, disk-space maximization, Docker restart, and Buildx setup. Change push paths to:

```yaml
paths:
  - 'images.txt'
  - 'scripts/**'
  - '.github/workflows/docker.yaml'
```

Replace inline parsing with:

```yaml
- name: Login to Aliyun Registry
  run: |
    echo "$ALIYUN_REGISTRY_PASSWORD" |
      docker login --username "$ALIYUN_REGISTRY_USER" \
        --password-stdin "$ALIYUN_REGISTRY"

- name: Sync Images
  run: bash scripts/sync-images.sh images.txt
```

- [ ] **Step 3: Document exact naming and sync behavior**

Update README sections to state:

```text
name/image:tag -> name_image:tag
ghcr.io/immich-app/immich-server:release
  -> <registry>/<namespace>/immich-app_immich-server:release
--platform=linux/arm64 xiaoyaliu/alist
  -> <registry>/<namespace>/xiaoyaliu_alist_linux_arm64:latest
```

Also document config-digest-based skip/refresh (compare source and target config blob sha256 via `skopeo inspect --config`; mismatched or missing target triggers an automatic re-sync, no manual ACR deletion needed), overall failure after processing remaining images, and both platform syntaxes.

- [ ] **Step 4: Run full verification**

Run:

```bash
bash tests/image-name-test.sh
bash tests/sync-images-test.sh
bash -n scripts/image-name.sh
bash -n scripts/sync-images.sh
ruby -e "require 'yaml'; YAML.parse_file('.github/workflows/docker.yaml')"
git diff --check
```

Expected: every command exits `0`; tests report all assertions passed; no YAML parse or whitespace errors.
