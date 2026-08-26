#!/usr/bin/env bash

set -euo pipefail

run_id=${1:?Usage: resolve-candidate-artifact.sh RUN_ID MAX_ATTEMPT [OUTPUT_FILE]}
max_attempt=${2:?Usage: resolve-candidate-artifact.sh RUN_ID MAX_ATTEMPT [OUTPUT_FILE]}
output_file=${3:-${GITHUB_OUTPUT:-}}

if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  echo "Invalid workflow run ID: $run_id" >&2
  exit 1
fi
if [[ ! "$max_attempt" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid workflow run attempt: $max_attempt" >&2
  exit 1
fi
if [[ ! "${GITHUB_REPOSITORY:-}" =~ ^[^/]+/[^/]+$ ]]; then
  echo "GITHUB_REPOSITORY must contain owner/repository" >&2
  exit 1
fi
if [[ -z "$output_file" ]]; then
  echo "GITHUB_OUTPUT or an explicit output file is required" >&2
  exit 1
fi

prefix="paperless-ngx-candidate-${run_id}-"
artifact_pages=$(gh api --paginate --slurp \
  "/repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/artifacts?per_page=100")

if ! candidate=$(jq -cer \
  --arg prefix "$prefix" \
  --argjson max_attempt "$max_attempt" '
    [
      .[].artifacts[]
      | select(.expired == false)
      | select(.name | startswith($prefix))
      | . as $artifact
      | ($artifact.name | ltrimstr($prefix)) as $attempt
      | select($attempt | test("^[1-9][0-9]*$"))
      | $artifact + {candidate_attempt: ($attempt | tonumber)}
      | select(.candidate_attempt <= $max_attempt)
    ]
    | sort_by(.candidate_attempt, .id)
    | last // empty
  ' <<<"$artifact_pages"); then
  echo "No unexpired candidate artifact found for run ${run_id} through attempt ${max_attempt}" >&2
  exit 1
fi

artifact_id=$(jq -r '.id' <<<"$candidate")
artifact_name=$(jq -r '.name' <<<"$candidate")
artifact_attempt=$(jq -r '.candidate_attempt' <<<"$candidate")
artifact_digest=$(jq -r '.digest // "unavailable"' <<<"$candidate")

{
  printf 'id=%s\n' "$artifact_id"
  printf 'name=%s\n' "$artifact_name"
  printf 'attempt=%s\n' "$artifact_attempt"
  printf 'digest=%s\n' "$artifact_digest"
} >>"$output_file"

echo "Resolved ${artifact_name} (ID ${artifact_id}, digest ${artifact_digest})"
