#!/usr/bin/env bash

set -euo pipefail

HARBOR_URL=  # set in .env, without trailing slash
HARBOR_NAME= # set in .env, name for registry field in metrics
HARBOR_USER= # set in .env
HARBOR_PASS= # set in .env

EXPORTER_ID="${EXPORTER_ID:-UNKNOWN}" # to be set by CI, i.e. to ENV_NAME or something like that; to be able to filter data collected by test from prod data
DEBUG=

PROJECT_BLACKLIST_REGEX= # i.e.: "^(d8|library)$"
PROJECT_WHITELIST_REGEX=

DOT_ENV_FILE="${DOT_ENV_FILE:-.env}"
# PROMETHEUS_TIMESTAMP="${PROMETHEUS_TIMESTAMP:-$(date '+%s%3N')}" # commented out because %3N does not work in alpine
PROMETHEUS_TIMESTAMP="${PROMETHEUS_TIMESTAMP:-$(date '+%s')000}"

. "$DOT_ENV_FILE"

# Harbor API page size
PAGE_SIZE=100

TEMP_DIR=
cleanup() {
  if [[ -n "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT
TEMP_DIR="$(mktemp -t -d harbor-stats.XXXXXXXX)"

debug() {
  [[ -z "${DEBUG:-}" ]] && return
  echo >&2 "DEBUG: $@"
}

# Call Harbor API with paging and return all items
harbor_api_all_pages() {
  local ENDPOINT="$1"
  local PAGE=1
  while :; do
    DATA=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
      "$HARBOR_URL${ENDPOINT}?page=$PAGE&page_size=$PAGE_SIZE")
    COUNT=$(echo "$DATA" | jq 'length')
    if [ "$COUNT" -eq 0 ]; then
      break
    fi
    # echo "$DATA" | jq -c '.[]'
    echo "$DATA"
    PAGE=$((PAGE+1))
  done | jq -s add
}

# Fetch all projects
get_projects() {
  harbor_api_all_pages "/api/v2.0/projects"
}

# Fetch repositories for a given project
get_repositories() {
  local PROJECT_NAME="$1"
  debug "get_repositories(PROJECT_NAME: $PROJECT_NAME)"
  harbor_api_all_pages "/api/v2.0/projects/${PROJECT_NAME}/repositories"
}

# Fetch artifacts for a given repository
get_artifacts() {
  local PROJECT_NAME="$1"
  local REPO_NAME="$2"
  local REPO_TRIMMED="${REPO_NAME#${PROJECT_NAME}/}" # remove leading "PROJECT_NAME/"
  local REPO_ENCODED
  REPO_ENCODED=$(echo -n "$REPO_TRIMMED" | sed 's/\//%252F/g')

  debug "get_artifacts(PROJECT_NAME=$PROJECT_NAME, REPO_ENCODED=$REPO_ENCODED)"

  harbor_api_all_pages "/api/v2.0/projects/${PROJECT_NAME}/repositories/${REPO_ENCODED}/artifacts"
}

# --- MAIN LOGIC ---

echo "# HELP harbor_project_artifact_count Number of artifacts stored per-project"
echo "# TYPE harbor_project_artifact_count gauge"
echo "# HELP harbor_project_artifact_total_size_bytes Total size of ALL DUPLICATED COPIES of artifacts per-project in bytes"
echo "# TYPE harbor_project_artifact_total_size_bytes gauge"
echo "# HELP harbor_project_repo_artifact_count Number of artifacts stored per-project-repo"
echo "# TYPE harbor_project_repo_artifact_count gauge"
echo "# HELP harbor_project_repo_artifact_total_size_bytes Total size of ALL DUPLICATED COPIES of artifacts per-project-repo in bytes"
echo "# TYPE harbor_project_repo_artifact_total_size_bytes gauge"

for PROJECT in $(get_projects | jq -r '.[].name'); do
  [[ -n "$PROJECT_BLACKLIST_REGEX" && "$PROJECT" =~ $PROJECT_BLACKLIST_REGEX ]] && { debug "project is blacklisted: $PROJECT"; continue; }
  [[ -n "$PROJECT_WHITELIST_REGEX" && ! "$PROJECT" =~ $PROJECT_WHITELIST_REGEX ]] && { debug "project is not whitelisted: $PROJECT"; continue; }
  PROJECT_SIZE_TOTAL=0
  PROJECT_ARTIFACT_COUNT_TOTAL=0

  REPOS_FILE="$TEMP_DIR/repos.json"
  # pipe through jq './/[]' because for empty projects it returns null
  get_repositories "$PROJECT" | jq './/[]' > "$REPOS_FILE"

  # Iterate over repositories in project
  for REPO in $(jq -r '.[] | select(.artifact_count > 0) | .name' "$REPOS_FILE"); do
    ARTIFACT_COUNT="$(jq -r '.[] | select(.name=="'"$REPO"'") | .artifact_count' "$REPOS_FILE")"
    ARTIFACT_SIZES=$(get_artifacts "$PROJECT" "$REPO" | jq -r '.[].size // 0')
    REPO_SIZE_TOTAL=0
    for SIZE in $ARTIFACT_SIZES; do
      REPO_SIZE_TOTAL=$((REPO_SIZE_TOTAL + SIZE))
    done
    PROJECT_SIZE_TOTAL=$((PROJECT_SIZE_TOTAL + REPO_SIZE_TOTAL))
    PROJECT_ARTIFACT_COUNT_TOTAL=$((PROJECT_ARTIFACT_COUNT_TOTAL + ARTIFACT_COUNT))
    echo "harbor_project_repo_artifact_count{exporter_id=\"$EXPORTER_ID\",registry=\"$HARBOR_NAME\",project=\"$PROJECT\",repo=\"$REPO\"} $ARTIFACT_COUNT $PROMETHEUS_TIMESTAMP"
    echo "harbor_project_repo_artifact_total_size_bytes{exporter_id=\"$EXPORTER_ID\",registry=\"$HARBOR_NAME\",project=\"$PROJECT\",repo=\"$REPO\"} $REPO_SIZE_TOTAL $PROMETHEUS_TIMESTAMP"
  done

  echo "harbor_project_artifact_count{exporter_id=\"$EXPORTER_ID\",registry=\"$HARBOR_NAME\",project=\"$PROJECT\"} $PROJECT_ARTIFACT_COUNT_TOTAL $PROMETHEUS_TIMESTAMP"
  echo "harbor_project_artifact_total_size_bytes{exporter_id=\"$EXPORTER_ID\",registry=\"$HARBOR_NAME\",project=\"$PROJECT\"} $PROJECT_SIZE_TOTAL $PROMETHEUS_TIMESTAMP"
done
