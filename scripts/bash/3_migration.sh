#!/usr/bin/env bash
# GHEC -> GHEC parallel migration runner (GitHub Actions optimized)
# - Configurable via CLI parameters
# - Keeps status bar and CSV writes
# - Background jobs write only to log files; parent prints log stream deltas
# - Robust completion parsing so "failed" increments correctly
set -o pipefail

############################################
# CLI args
############################################
MAX_CONCURRENT=10
CSV_PATH="repos.csv"
OUTPUT_PATH="" # empty -> timestamped file

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-concurrent)
      MAX_CONCURRENT="$2"; shift 2;;
    --csv)
      CSV_PATH="$2"; shift 2;;
    --output)
      OUTPUT_PATH="$2"; shift 2;;
    -*|--*)
      echo -e "\033[31m[ERROR] Unknown option: $1\033[0m"; exit 1;;
    *)
      echo -e "\033[31m[ERROR] Unexpected positional arg: $1\033[0m"; exit 1;;
  esac
done

############################################
# Validate settings
############################################
if [[ -z "${MAX_CONCURRENT}" || ! "${MAX_CONCURRENT}" =~ ^[0-9]+$ ]]; then
  echo -e "\033[31m[ERROR] --max-concurrent must be an integer\033[0m"; exit 1
fi

if [[ "${MAX_CONCURRENT}" -gt 10 ]]; then
  echo -e "\033[31m[ERROR] Maximum concurrent migrations (${MAX_CONCURRENT}) exceeds the allowed limit of 10.\033[0m"
  echo -e "\033[31m[ERROR] Please set --max-concurrent to 10 or less.\033[0m"
  exit 1
fi

if [[ "${MAX_CONCURRENT}" -lt 1 ]]; then
  echo -e "\033[31m[ERROR] --max-concurrent must be at least 1.\033[0m"; exit 1
fi

# Normalize CRLF if present (Windows-generated CSV)
sed -i 's/\r$//' "${CSV_PATH}" 2>/dev/null || true

if [[ ! -f "${CSV_PATH}" ]]; then
  echo -e "\033[31m[ERROR] CSV file not found: ${CSV_PATH}\033[0m"; exit 1
fi

if [[ -z "${OUTPUT_PATH}" ]]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_CSV_PATH="repos_with_status.csv"
else
  OUTPUT_CSV_PATH="${OUTPUT_PATH}"
fi

############################################
# Required environment (GEI)
############################################
: "${SOURCE_PAT:?Environment variable SOURCE_PAT is not set}"
: "${TARGET_PAT:?Environment variable TARGET_PAT is not set}"


# GEI expects target authentication in GH_PAT
export GH_PAT="${TARGET_PAT}"
export GH_SOURCE_PAT="${SOURCE_PAT}"

# Source API configuration
SOURCE_API_URL="${SOURCE_API_URL:-https://api.github.com}"
SOURCE_API_URL="${SOURCE_API_URL%/}"

SOURCE_API_ARGS=()

# Pass source API URL only for GHEC Data Residency sources
if [[ "${SOURCE_API_URL}" != "https://api.github.com" ]]; then
    SOURCE_API_ARGS+=(--github-source-api-url "${SOURCE_API_URL}")
fi

# NEW: Handle GH_SOURCE_API_URL environment variable
if [[ "${SOURCE_API_URL}" == "https://api.github.com" ]]; then
    unset GH_SOURCE_API_URL
else
    export GH_SOURCE_API_URL="${SOURCE_API_URL}"
fi

# Target API configuration
TARGET_API_URL="${TARGET_API_URL:-https://api.github.com}"
TARGET_API_URL="${TARGET_API_URL%/}"

TARGET_API_ARGS=()

# Pass target API URL only for GHEC Data Residency targets
if [[ "${TARGET_API_URL}" != "https://api.github.com" ]]; then
    TARGET_API_ARGS+=(--target-api-url "${TARGET_API_URL}")
fi

############################################
# CSV helpers
############################################
# Robust CSV line parser (quoted fields, escaped quotes)
parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next
  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"
    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'; ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done
  fields+=("${field}")
  printf '%s\n' "${fields[@]}"
}

# Strip a single leading and trailing double-quote if present (no eval)
strip_quotes() {
  local s="$1"
  [[ ${s} == \"* ]] && s="${s#\"}"
  [[ ${s} == *\" ]] && s="${s%\"}"
  printf '%s' "$s"
}

# Header check: require these columns anywhere in header order
# repos.csv schema: source_org,source_repo,repo_url,repo_size_MB,target_org,target_repo,target_repo_visibility
REQUIRED_COLUMNS=(source_org source_repo target_org target_repo target_repo_visibility)
read -r HEADER_LINE < "${CSV_PATH}"
mapfile -t HEADER_FIELDS < <(parse_csv_line "${HEADER_LINE}")

# Build an index map: name -> position
declare -A COLIDX=()
for idx in "${!HEADER_FIELDS[@]}"; do
  name="${HEADER_FIELDS[$idx]}"
  name="${name%\"}"; name="${name#\"}"
  COLIDX["$name"]="$idx"
done

# Validate required columns exist
missing=()
for col in "${REQUIRED_COLUMNS[@]}"; do
  [[ -n "${COLIDX[$col]:-}" ]] || missing+=("$col")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo -e "\033[31m[ERROR] CSV missing required columns: ${missing[*]}\033[0m"
  echo -e "\033[31m[ERROR] Required: ${REQUIRED_COLUMNS[*]}\033[0m"
  exit 1
fi

############################################
# Status CSV writers
############################################
write_migration_status_csv_header() {
  echo "source_org,source_repo,target_org,target_repo,target_repo_visibility,Migration_Status,Log_File" > "${OUTPUT_CSV_PATH}"
}

append_status_row() {
  # args: source_org source_repo target_org target_repo target_repo_visibility status log_file
  printf '\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "${OUTPUT_CSV_PATH}"
}

update_repo_status_in_csv() {
  local search_target_repo="$1" new_status="$2" log_file="$3"
  local tmp; tmp="$(mktemp)"
  {
    head -n 1 "${OUTPUT_CSV_PATH}"
    tail -n +2 "${OUTPUT_CSV_PATH}" |
    while IFS= read -r line; do
      mapfile -t F < <(parse_csv_line "${line}")
      local source_org; source_org="$(strip_quotes "${F[0]}")"
      local source_repo; source_repo="$(strip_quotes "${F[1]}")"
      local target_org; target_org="$(strip_quotes "${F[2]}")"
      local target_repo; target_repo="$(strip_quotes "${F[3]}")"
      local target_repo_visibility; target_repo_visibility="$(strip_quotes "${F[4]}")"
      local status; status="$(strip_quotes "${F[5]}")"
      local cur_log; cur_log="$(strip_quotes "${F[6]}")"
      if [[ "${target_repo}" == "${search_target_repo}" ]]; then
        printf '\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n' \
          "${source_org}" "${source_repo}" "${target_org}" "${target_repo}" \
          "${target_repo_visibility}" "${new_status}" "${log_file}"
      else
        printf '\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n' \
          "${source_org}" "${source_repo}" "${target_org}" "${target_repo}" \
          "${target_repo_visibility}" "${status}" "${cur_log}"
      fi
    done
  } > "${tmp}"
  mv "${tmp}" "${OUTPUT_CSV_PATH}"
}

############################################
# Migration function (no console noise)
############################################
migrate_repository() {
  local source_org="$1" source_repo="$2"
  local target_org="$3" target_repo="$4" target_repo_visibility="$5"
  local log_file="$6"
  {
    printf '[%s] [START] Migration: %s/%s -> %s/%s (visibility: %s)\n' \
      "$(date)" "${source_org}" "${source_repo}" "${target_org}" "${target_repo}" "${target_repo_visibility}"
    #printf '[%s] [DEBUG] Running: gh gei migrate-repo --github-source-org %s --source-repo %s --github-target-org %s --target-repo %s --target-repo-visibility %s --target-api-url %s\n' \
    printf '[%s] [DEBUG] Running migration: %s/%s -> %s/%s\n' \
      "$(date)" "${source_org}" "${source_repo}" "${target_org}" "${target_repo}"

    # Run migration: append output ONLY to log file (no tee to stdout)
    gh gei migrate-repo \
      --github-source-org "${source_org}" \
      --source-repo "${source_repo}" \
      --github-target-org "${target_org}" \
      --target-repo "${target_repo}" \
      --target-repo-visibility "${target_repo_visibility}" \
      --github-source-pat "${SOURCE_PAT}" \
      --github-target-pat "${TARGET_PAT}" \
      "${SOURCE_API_ARGS[@]}" \
      "${TARGET_API_ARGS[@]}"

    
    # Assess log content (keep same style checks as ADO runner)
    if grep -q "No operation will be performed" "${log_file}"; then
      printf '[%s] [FAILED] No operation performed - repository may already exist or migration was skipped\n' "$(date)" >> "${log_file}"
      return 1
    fi

    # Success heuristics (GEI commonly reports SUCCEEDED; keep a tolerant check)
    if ! grep -Eq "State: SUCCEEDED|SUCCEEDED" "${log_file}"; then
      printf '[%s] [FAILED] Migration did not reach SUCCEEDED state\n' "$(date)" >> "${log_file}"
      return 1
    fi

    printf '[%s] [SUCCESS] Migration: %s/%s -> %s/%s\n' \
      "$(date)" "${source_org}" "${source_repo}" "${target_org}" "${target_repo}" >> "${log_file}"
    return 0
  } >> "${log_file}" 2>&1
}

############################################
# Queues and tracking
############################################
declare -A JOB_PIDS=()   # pid -> "source_org,source_repo,target_org,target_repo,target_repo_visibility"
declare -A JOB_LOGS=()   # pid -> log file
declare -A JOB_REPOS=()  # pid -> target_repo
declare -A JOB_LASTLEN=() # pid -> last printed length
QUEUE=()
MIGRATED=()
FAILED=()

############################################
# Load queue from CSV rows (skip header)
############################################
LINE_NUM=0
while IFS= read -r line; do
  ((LINE_NUM++))
  [[ ${LINE_NUM} -eq 1 ]] && continue
  mapfile -t F < <(parse_csv_line "${line}")

  # Pull required columns by header indices (robust to column order)
  source_org="${F[${COLIDX[source_org]}]}"
  source_repo="${F[${COLIDX[source_repo]}]}"
  target_org="${F[${COLIDX[target_org]}]}"
  target_repo="${F[${COLIDX[target_repo]}]}"
  target_repo_visibility="${F[${COLIDX[target_repo_visibility]}]}"

  # Trim quotes (single pair)
  source_org="$(strip_quotes "$source_org")"
  source_repo="$(strip_quotes "$source_repo")"
  target_org="$(strip_quotes "$target_org")"
  target_repo="$(strip_quotes "$target_repo")"
  target_repo_visibility="$(strip_quotes "$target_repo_visibility")"

  # Basic presence check
  if [[ -z "${source_org}" || -z "${source_repo}" || -z "${target_org}" || -z "${target_repo}" || -z "${target_repo_visibility}" ]]; then
    echo "[WARNING] Skipping malformed line ${LINE_NUM}: missing required columns"
    echo "Migration will be skipped. Please ensure source_org, source_repo, target_org, target_repo and target_repo_visibility are populated."
    exit 1
  fi

  QUEUE+=("${source_org},${source_repo},${target_org},${target_repo},${target_repo_visibility}")
done < "${CSV_PATH}"

############################################
# Initialize output CSV with Pending
############################################
write_migration_status_csv_header
for item in "${QUEUE[@]}"; do
  IFS=',' read -r source_org source_repo target_org target_repo target_repo_visibility <<< "${item}"
  append_status_row "${source_org}" "${source_repo}" "${target_org}" "${target_repo}" "${target_repo_visibility}" "Pending" ""
done

echo "[INFO] Starting migration with ${MAX_CONCURRENT} concurrent jobs..."
echo "[INFO] Processing ${#QUEUE[@]} repositories from: ${CSV_PATH}"
echo "[INFO] Initialized migration status output: ${OUTPUT_CSV_PATH}"

############################################
# Status bar (PS-style width stabilization)
############################################
STATUS_LINE_WIDTH=0
show_status_bar() {
  local queue_count=${#QUEUE[@]}
  local progress_count=${#JOB_PIDS[@]}
  local migrated_count=${#MIGRATED[@]}
  local failed_count=${#FAILED[@]}
  local status="QUEUE: ${queue_count} IN PROGRESS: ${progress_count} MIGRATED: ${migrated_count} MIGRATION FAILED: ${failed_count}"
  (( ${#status} > STATUS_LINE_WIDTH )) && STATUS_LINE_WIDTH=${#status}
  printf "\r\033[36m%-${STATUS_LINE_WIDTH}s\033[0m" "${status}"
}

############################################
# Main loop
############################################
while (( ${#QUEUE[@]} > 0 )) || (( ${#JOB_PIDS[@]} > 0 )); do
  # Start new jobs up to concurrency
  while (( ${#JOB_PIDS[@]} < MAX_CONCURRENT )) && (( ${#QUEUE[@]} > 0 )); do
    repo_info="${QUEUE[0]}"
    QUEUE=("${QUEUE[@]:1}")

    IFS=',' read -r source_org source_repo target_org target_repo target_repo_visibility <<< "${repo_info}"
    log_file="migration-${target_repo}-$(date +%Y%m%d-%H%M%S).txt"

    # Update CSV with "In Progress" + log file
    update_repo_status_in_csv "${target_repo}" "In Progress" "${log_file}"

    ( 
      if migrate_repository "${source_org}" "${source_repo}" "${target_org}" "${target_repo}" "${target_repo_visibility}" "${log_file}"; then
        echo "SUCCESS" > "${log_file}.result"
      else
        echo "FAILED" > "${log_file}.result"
      fi
    ) &

    pid=$!
    JOB_PIDS["$pid"]="${repo_info}"
    JOB_LOGS["$pid"]="${log_file}"
    JOB_REPOS["$pid"]="${target_repo}"
    JOB_LASTLEN["$pid"]=0

    show_status_bar
  done

  # Stream new log content from each job (delta only)
  for pid in "${!JOB_PIDS[@]}"; do
    log="${JOB_LOGS[$pid]}"
    last="${JOB_LASTLEN[$pid]}"
    if [[ -f "${log}" ]]; then
      new_len=$(wc -c < "${log}")
      if (( new_len > last )); then
        delta_bytes=$(( new_len - last ))
        echo ""
        tail -c "${delta_bytes}" "${log}" | tr -d '\r' | while IFS= read -r l; do
          [[ -n "${l}" ]] && echo "${l}"
        done
        JOB_LASTLEN["$pid"]="${new_len}"
        show_status_bar
      fi
    fi
  done

  # Check completed jobs (use ps to avoid reused PID false-positives)
  for pid in "${!JOB_PIDS[@]}"; do
    if ! ps -p "${pid}" > /dev/null 2>&1; then
      repo_info="${JOB_PIDS[$pid]}"
      log_file="${JOB_LOGS[$pid]}"
      target_repo="${JOB_REPOS[$pid]}"

      result="FAILED"
      if [[ -f "${log_file}.result" ]]; then
        result="$(<"${log_file}.result")"
        rm -f "${log_file}.result"
      fi

      if [[ "${result}" == "SUCCESS" ]]; then
        MIGRATED+=("${repo_info}")
        update_repo_status_in_csv "${target_repo}" "Success" "${log_file}"
      else
        FAILED+=("${repo_info}")
        update_repo_status_in_csv "${target_repo}" "Failure" "${log_file}"
      fi

      unset JOB_PIDS["$pid"] JOB_LOGS["$pid"] JOB_REPOS["$pid"] JOB_LASTLEN["$pid"]
      show_status_bar
    fi
  done

  sleep 2
done

echo
echo "[INFO] All migrations completed."
total_repos=$(( $(wc -l < "${CSV_PATH}") - 1 ))
echo "[SUMMARY] Total: ${total_repos} Migrated: ${#MIGRATED[@]} Failed: ${#FAILED[@]}"
echo "[INFO] Wrote migration results with Migration_Status column: ${OUTPUT_CSV_PATH}"

# Do not exit non-zero; let the workflow decide
if (( ${#FAILED[@]} > 0 )); then
  echo -e "\033[33m[WARNING] Migration completed with ${#FAILED[@]} failures\033[0m"
fi
