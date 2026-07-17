#!/usr/bin/env bash

# Sourceable GitHub API helpers. A confirmed HTTP 404 is returned as a distinct
# status so callers never confuse a transient API failure with a missing object.

GITHUB_API_NOT_FOUND_STATUS=44

github_api_error_is_transient() {
  local error_file="$1"

  grep -Eqi \
    'HTTP (429|5[0-9][0-9])|timed out|timeout|connection (reset|refused)|temporary failure|unexpected EOF' \
    "$error_file"
}

github_api_json_allow_404() {
  local attempts="${GITHUB_API_ATTEMPTS:-3}"
  local delay_seconds="${GITHUB_API_RETRY_DELAY_SECONDS:-2}"
  local attempt
  local error_file
  local output
  local status

  if [[ ! "$attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "GITHUB_API_ATTEMPTS must be a positive integer, got '$attempts'." >&2
    return 2
  fi
  if [[ ! "$delay_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "GITHUB_API_RETRY_DELAY_SECONDS must be a non-negative number, got '$delay_seconds'." >&2
    return 2
  fi

  error_file="$(mktemp)"
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    : > "$error_file"
    if output="$(gh api "$@" 2>"$error_file")"; then
      rm -f "$error_file"
      printf '%s\n' "$output"
      return 0
    else
      status=$?
    fi

    if grep -q 'HTTP 404' "$error_file"; then
      rm -f "$error_file"
      return "$GITHUB_API_NOT_FOUND_STATUS"
    fi

    cat "$error_file" >&2
    if ((attempt < attempts)) && github_api_error_is_transient "$error_file"; then
      echo "GitHub API request failed transiently; retrying ($attempt/$attempts)." >&2
      sleep "$delay_seconds"
      continue
    fi

    rm -f "$error_file"
    return "$status"
  done

  rm -f "$error_file"
  return 1
}

github_release_json_allow_404() {
  local tag="$1"

  github_api_json_allow_404 "repos/{owner}/{repo}/releases/tags/$tag"
}

github_release_assets_json_allow_404() {
  local release_json
  local status
  local tag="$1"

  if release_json="$(github_release_json_allow_404 "$tag")"; then
    jq -c '.assets // []' <<<"$release_json"
    return 0
  else
    status=$?
  fi

  return "$status"
}
