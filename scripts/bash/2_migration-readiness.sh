#!/usr/bin/env bash
# Export source authentication and API endpoint

export SOURCE_PAT="${SOURCE_PAT:-$2}"
export SOURCE_API_URL="${SOURCE_API_URL:-https://api.github.com}"

# Check if all required tokens are set
if [[ -z "$SOURCE_PAT" ]]; then
  echo -e "\033[31m[ERROR] SOURCE_PAT environment variable is not set. Please set your GitHub Source Personal Access Token.\033[0m"
  exit 1
fi

if [[ -z "$TARGET_PAT" ]]; then
  echo -e "\033[31m[ERROR] TARGET_PAT environment variable is not set. Please set your GitHub Target Personal Access Token.\033[0m"
  exit 1
fi

# Declare variables for consolidated summary
total_repos=0
repos_with_active_prs=0
repos_with_workflows=0
repos_with_open_issues=0

# Declare an array to store the results per repository
declare -A repo_results

# Read CSV file
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
csv_path="$script_dir/repos.csv"
if [[ ! -f "$csv_path" ]]; then
  echo "CSV file $csv_path not found. Exiting..."
  exit 1
else
  echo -e "\nReading input from file: '$csv_path'"
fi

# Function to URL encode strings (for proper API URLs)
urlencode() {
  local string="$1"
  local encoded=""
  for ((i = 0; i < ${#string}; i++)); do
    c="${string:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      *) encoded+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  echo -n "$encoded"
}

# Get active pull requests, workflows, and open issues for each repository
line_num=0
while IFS= read -r line; do
  ((line_num++))

  # Skip header line
  if [[ $line_num -eq 1 ]]; then
    continue
  fi

  # Parse the CSV line using comma as delimiter (use only first 2 columns from repos.csv schema)
  # repos.csv schema: source_org, source_repo, <ignore remaining columns>
  IFS=',' read -r source_org source_repo _rest <<< "$line"

  # Clean up quotes if present (fixed to avoid sed text being appended to values)
  source_org=$(echo "$source_org" | sed 's/^"//;s/"$//')
  source_repo=$(echo "$source_repo" | sed 's/^"//;s/"$//')

  # Ensure the values are not empty
  if [[ -z "$source_org" ]] || [[ -z "$source_repo" ]]; then
    echo -e "\033[31m[ERROR] Organization or repository name is empty. Skipping...\033[0m"
    continue
  fi

  # Debug: Check the values being extracted from the CSV
  echo "Processing Organization: '$source_org', Repository: '$source_repo'"

  enc_gh_org="$(urlencode "$source_org")"
  enc_selected_repo_name="$(urlencode "$source_repo")"

  # Correctly format the API URL for the specific org/repo
  pr_uri="$SOURCE_API_URL/repos/$enc_gh_org/$enc_selected_repo_name/pulls?state=open"
  pr_response=$(curl -s -H "Authorization: token $SOURCE_PAT" "$pr_uri" 2>/dev/null)

  # Initialize repository result
  repo_results["$source_repo"]=""

  # Check if response is valid for PRs
  if [[ $? -eq 0 ]] && [[ -n "$pr_response" ]]; then
    # Ensure numeric PR count even if API returns a "Not Found" JSON error
    pr_count=$(
      echo "$pr_response" | jq -r '
        if (type=="object" and (.message?=="Not Found")) then
          0
        else
          (length)
        end
      ' 2>/dev/null
    )
    pr_count=${pr_count:-0}

    total_repos=$((total_repos + 1))

    # Active PR check
    if [[ "$pr_count" -gt 0 ]]; then
      repos_with_active_prs=$((repos_with_active_prs + 1))
      repo_results["$source_repo"]="Active PR"
    fi

    # Check if workflows exist and are running or queued
    workflows_uri="$SOURCE_API_URL/repos/$enc_gh_org/$enc_selected_repo_name/actions/runs"
    workflows_response=$(curl -s -H "Authorization: token $SOURCE_PAT" "$workflows_uri" 2>/dev/null)

    # Check for running or queued workflows (numeric-safe even on 404/unsupported endpoints)
    running_or_queued_workflows_count=$(
      echo "$workflows_response" | jq -r '
        if (type=="object" and (.message?=="Not Found" or (.workflow_runs?==null))) then
          0
        else
          ([.workflow_runs[]? | select(.status=="in_progress" or .status=="queued")] | length)
        end
      ' 2>/dev/null
    )
    running_or_queued_workflows_count=${running_or_queued_workflows_count:-0}

    if [[ "$running_or_queued_workflows_count" -gt 0 ]]; then
      repos_with_workflows=$((repos_with_workflows + 1))
      # Append Workflow status to the repo result
      if [[ -z "${repo_results["$source_repo"]}" ]]; then
        repo_results["$source_repo"]="Workflow (Running or Queued)"
      else
        repo_results["$source_repo"]="${repo_results["$source_repo"]}, Workflow (Running or Queued)"
      fi
    fi

    # Check for open issues (excluding pull requests)
    open_issues_uri="$SOURCE_API_URL/repos/$enc_gh_org/$enc_selected_repo_name/issues?state=open"
    open_issues_response=$(curl -s -H "Authorization: token $SOURCE_PAT" "$open_issues_uri" 2>/dev/null)

    # Numeric-safe open issues count even on 404
    open_issues_count=$(
      echo "$open_issues_response" | jq -r '
        if (type=="object" and (.message?=="Not Found")) then
          0
        else
          ([.[]? | select(.pull_request? == null)] | length)
        end
      ' 2>/dev/null
    )
    open_issues_count=${open_issues_count:-0}

    if [[ "$open_issues_count" -gt 0 ]]; then
      repos_with_open_issues=$((repos_with_open_issues + 1))
      # Append Open Issues status to the repo result
      if [[ -z "${repo_results["$source_repo"]}" ]]; then
        repo_results["$source_repo"]="Open Issues"
      else
        repo_results["$source_repo"]="${repo_results["$source_repo"]}, Open Issues"
      fi
    fi
  else
    echo -e "\033[31m[ERROR] Failed to process PRs for repository '$source_repo'.\033[0m"
  fi

  # If there are no active/open items, set "No Active/Open Items"
  if [[ -z "${repo_results["$source_repo"]}" ]]; then
    repo_results["$source_repo"]="\033[32mNo Active/Open Items\033[0m"
  fi
done < "$csv_path"

# Final Consolidated Summary
echo -e "\nPre-Migration Consolidated Summary"
echo "====================================="
echo "Total Repositories Processed: $total_repos"
echo "Repositories with Active Pull Requests: $repos_with_active_prs"
echo "Repositories with Workflows (Running or Queued): $repos_with_workflows"
echo "Repositories with Open Issues: $repos_with_open_issues"

if [[ "$repos_with_active_prs" -gt 0 ]]; then
  echo -e "\033[33mWarning: Some repositories have active pull requests. Please review them before proceeding.\033[0m"
fi
if [[ "$repos_with_open_issues" -gt 0 ]]; then
  echo -e "\033[33mWarning: Some repositories have open issues. Please review them before proceeding.\033[0m"
fi
if [[ "$total_repos" -eq 0 ]]; then
  echo -e "\033[31m[ERROR] No repositories were processed. Please check your CSV file.\033[0m"
  exit 1
fi

# Print concise repository results
echo -e "\nRepository-Specific Results:"
echo "============================="
for repo in "${!repo_results[@]}"; do
  echo -e "$repo: ${repo_results[$repo]}"
done
echo "============================="
echo -e "\nMigration validation complete. You can now proceed with migration if the necessary checks are met."
