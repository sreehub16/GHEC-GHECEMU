#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Required environment variables
# ----------------------------
: "${SOURCE_PAT:?SOURCE_PAT not set}"
: "${TARGET_PAT:?TARGET_PAT not set}"

export GH_PAT="${TARGET_PAT}"
SOURCE_API_URL="${SOURCE_API_URL:-https://api.github.com}"
TARGET_API_URL="${TARGET_API_URL:-https://api.github.com}"


# Remove trailing slashes
SOURCE_API_URL="${SOURCE_API_URL%/}"
TARGET_API_URL="${TARGET_API_URL%/}"

# ----------------------------
# Logging
# ----------------------------
LOG_FILE="validation-log-$(date +%Y%m%d).txt"


write_log() {
  echo "$1" | tee -a "$LOG_FILE"
}

# ----------------------------
# Helpers
# ----------------------------
is_json() { jq -e . >/dev/null 2>&1; }

urlencode() {
  jq -rn --arg s "$1" '$s|@uri'
}

# ----------------------------
# source pagination
# ----------------------------
get_source_branches_json() {
  local org="$1"
  local repo="$2"
  local page=1
  local per_page=100
  local all='[]'

  local enc_org enc_repo
  enc_org="$(urlencode "$org")"
  enc_repo="$(urlencode "$repo")"

  while true; do
    local url="${SOURCE_API_URL}/repos/${enc_org}/${enc_repo}/branches?page=$page&per_page=$per_page"

    local resp
    resp="$(curl -sS \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: token ${SOURCE_PAT}" \
      "$url")"

    if ! echo "$resp" | is_json; then
      write_log "❌ Invalid JSON response from source branches API for ${org}/${repo}"
      break
    fi

    local batch_len
    if ! echo "$resp" | jq -e 'type=="array"' >/dev/null; then
      write_log "❌ Source branch API failed for ${org}/${repo}: $(echo "$resp" | jq -r '.message')"
      break
    fi
    batch_len="$(echo "$resp" | jq 'length')"

    all="$(jq -c -n --argjson a "$all" --argjson b "$resp" '$a + $b')"

    [[ "$batch_len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "$all"
}

# ----------------------------
# Target GHEC pagination
# ----------------------------
get_target_branches_json() {
  local org="$1"
  local repo="$2"
  local page=1
  local per_page=100
  local all='[]'

  while true; do
    local resp
    resp="$(curl -sS \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token ${TARGET_PAT}" \
    "${TARGET_API_URL}/repos/$(urlencode "$org")/$(urlencode "$repo")/branches?page=$page&per_page=$per_page")" || {
      write_log "❌ Failed to fetch Target branches for ${org}/${repo}"
      break
    }

    if ! echo "$resp" | is_json; then
      write_log "❌ Invalid JSON response from Target branches API for ${org}/${repo}"
      break
    fi

    local batch_len
    if ! echo "$resp" | jq -e 'type=="array"' >/dev/null; then
      write_log "❌ Target branch API failed for ${org}/${repo}: $(echo "$resp" | jq -r '.message')"
      break
    fi
    batch_len="$(echo "$resp" | jq 'length')"

    all="$(jq -c -n --argjson a "$all" --argjson b "$resp" '$a + $b')"

    [[ "$batch_len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "$all"
}

# ----------------------------
# Commit comparison
# ----------------------------
get_latest_commit_sha() {

  local api_url="$1"
  local token="$2"
  local org="$3"
  local repo="$4"
  local branch="$5"

  local enc_branch
  enc_branch="$(urlencode "$branch")"

  local resp

  resp="$(curl -sS \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token ${token}" \
    "${api_url}/repos/$(urlencode "$org")/$(urlencode "$repo")/commits?sha=${enc_branch}&per_page=1")"

  if ! echo "$resp" | is_json; then
      echo ""
      return
  fi

  echo "$resp" | jq -r '.[0].sha // empty'
}

# ----------------------------
# Validation
# ----------------------------
validate_migration() {
  local source_org="$1"
  local source_repo="$2"
  local target_org="$3"
  local target_repo="$4"

  write_log ""
  write_log "============================================================"
  write_log "ℹ️  [$(date -u +%FT%TZ)] Validating: ${source_org}/${source_repo} -> ${target_org}/${target_repo}"
  write_log "============================================================"

  local target_branches source_branches

  target_branches="$(get_target_branches_json "$target_org" "$target_repo")"
  source_branches="$(get_source_branches_json "$source_org" "$source_repo")"

  # ✅ FULL arrays (no limit here)
  mapfile -t target_array < <(echo "$target_branches" | jq -r '.[].name')
  mapfile -t source_array < <(echo "$source_branches" | jq -r '.[].name')

  # ----------------------------
  # Branch validation (FULL)
  # ----------------------------
  declare -A target_map
  declare -A source_map

  local b

  for b in "${target_array[@]}"; do
    target_map["$b"]=1
  done

  for b in "${source_array[@]}"; do
    source_map["$b"]=1
  done

  local missing_in_target=()
  local missing_in_source=()

  for b in "${source_array[@]}"; do
    [[ -z "${target_map[$b]:-}" ]] && missing_in_target+=("$b")
  done

  for b in "${target_array[@]}"; do
    [[ -z "${source_map[$b]:-}" ]] && missing_in_source+=("$b")
  done

  # ✅ Branch count (UNCHANGED)
  if [[ ${#source_array[@]} -eq ${#target_array[@]} ]]; then
    write_log "✅ Branch Count MATCHED | source=${#source_array[@]} Target=${#target_array[@]}"
  else
    write_log "❌ Branch Count NOT MATCHED | source=${#source_array[@]} Target=${#target_array[@]}"
  fi

  # Missing
  [[ ${#missing_in_target[@]} -gt 0 ]] && \
    write_log "⚠️ Missing in Target: ${missing_in_target[*]}" || \
    write_log "✅ No branches missing in Target"

  [[ ${#missing_in_source[@]} -gt 0 ]] && \
    write_log "⚠️ Extra in Target / Missing in Source: ${missing_in_source[*]}" || \
    write_log "✅ No extra branches found"


  # ----------------------------
  # ✅ LIMIT ONLY FOR SHA VALIDATION
  # Default branch + maximum 9 additional branches
  # ----------------------------

  default_branch="$(curl -sS \
  -H "Authorization: token ${TARGET_PAT}" \
  "${TARGET_API_URL}/repos/$(urlencode "$target_org")/$(urlencode "$target_repo")" \
  | jq -r '.default_branch')"


  target_limited_array=()

  # Always validate default branch first
  target_limited_array+=("$default_branch")


  # Add maximum 9 non-default branches
  for b in "${target_array[@]}"; do

      [[ "$b" == "$default_branch" ]] && continue

      target_limited_array+=("$b")

      [[ ${#target_limited_array[@]} -eq 10 ]] && break

  done

  write_log "ℹ️ SHA validation running for default branch + maximum 9 additional branches"

  # ----------------------------
  # SHA validation (LIMITED)
  # ----------------------------
  local branch
  local target_sha
  local source_sha

  for branch in "${target_limited_array[@]}"; do

      [[ -z "${source_map[$branch]:-}" ]] && continue

      target_sha="$(get_latest_commit_sha \
          "$TARGET_API_URL" \
          "$TARGET_PAT" \
          "$target_org" \
          "$target_repo" \
          "$branch")"


      source_sha="$(get_latest_commit_sha \
          "$SOURCE_API_URL" \
          "$SOURCE_PAT" \
          "$source_org" \
          "$source_repo" \
          "$branch")"


      if [[ "$source_sha" == "$target_sha" && -n "$source_sha" ]]; then
          write_log "Branch '$branch': Source SHA=$source_sha | Target SHA=$target_sha | ✅ Matching"
      else
          write_log "Branch '$branch': Source SHA=$source_sha | Target SHA=$target_sha | ❌ NOT Matching"
      fi
  done
  write_log "✅ Validation completed for: ${target_org}/${target_repo}"

}

# ----------------------------
# CSV Processing
# ----------------------------
validate_from_csv() {
  local csv="repos_with_status.csv"

  [[ ! -f "$csv" ]] && {
    write_log "❌ CSV file not found: $csv"
    exit 1
  }

  tail -n +2 "$csv" | while IFS=',' read -r source_org source_repo target_org target_repo target_repo_visibility migration_status log_file; do
    source_org=$(echo "$source_org" | tr -d '"')
    source_repo=$(echo "$source_repo" | tr -d '"')
    target_org=$(echo "$target_org" | tr -d '"')
    target_repo=$(echo "$target_repo" | tr -d '"')
    target_repo_visibility=$(echo "$target_repo_visibility" | tr -d '"')
    migration_status=$(echo "$migration_status" | tr -d '"')
    log_file=$(echo "$log_file" | tr -d '"')

    [[ -z "$source_org" || -z "$source_repo" || -z "$target_org" || -z "$target_repo" ]] && {
      write_log "⚠️ Skipping invalid row"
      continue
    }

    if [[ "${migration_status,,}" != "success" && "${migration_status,,}" != "succeeded" ]]; then
    write_log "⏭️ Skipping ${source_org}/${source_repo} because migration status is ${migration_status}"
    continue
    fi

    validate_migration "$source_org" "$source_repo" "$target_org" "$target_repo"

  done
}
validate_from_csv
