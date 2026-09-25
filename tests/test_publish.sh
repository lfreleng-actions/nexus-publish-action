#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Tests for scripts/publish.sh retry handling and maven2_upload upload
# ordering, run against the mock Nexus in tests/mock_nexus.py.
# Requires bash 4.4+, curl, python3 and md5sum/sha1sum/sha256sum.
#
# Usage: bash tests/test_publish.sh

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
mock_pid=""
mock_port=""
publish_exit=0
current_test=""
failures=0

# Distinctive value so any leak into logs or outputs is detectable
password='mock-secret-9f3c1e'

version_dir='org/example/demo/1.0-SNAPSHOT'
snapshot='demo-1.0-20260925.120000-1'

stop_mock() {
  if [ -n "$mock_pid" ]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
    mock_pid=""
  fi
}

cleanup() {
  stop_mock
  rm -rf "$work"
}
trap cleanup EXIT

# Start the mock with a MOCK_RESPONSES JSON document
start_mock() {
  rm -f "$work/port" "$work/requests.log"
  MOCK_RESPONSES="$1" \
    MOCK_LOG="$work/requests.log" \
    MOCK_PORT_FILE="$work/port" \
    python3 "$repo_root/tests/mock_nexus.py" &
  mock_pid=$!
  local _
  for _ in $(seq 1 50); do
    if [ -s "$work/port" ]; then
      mock_port=$(cat "$work/port")
      return 0
    fi
    sleep 0.1
  done
  echo "mock Nexus did not start"
  exit 1
}

# Create files (paths relative to the m2repo root) with dummy content
make_m2repo() {
  rm -rf "$work/m2repo"
  local file
  for file in "$@"; do
    mkdir -p "$(dirname "$work/m2repo/$file")"
    printf 'content of %s\n' "$file" > "$work/m2repo/$file"
  done
}

# Run publish.sh as action.yaml does; NAME=value arguments override
# the defaults below. Sets publish_exit.
run_publish() {
  : > "$work/github_output"
  : > "$work/step_summary"
  publish_exit=0
  env \
    INPUT_NEXUS_SERVER="http://127.0.0.1:${mock_port}" \
    INPUT_NEXUS_USERNAME='mock-user' \
    INPUT_NEXUS_PASSWORD="$password" \
    INPUT_REPOSITORY_NAME='snapshots' \
    INPUT_REPOSITORY_FORMAT='maven2_upload' \
    INPUT_FILES_PATH="$work/m2repo" \
    INPUT_FILE_PATTERN='*' \
    INPUT_UPLOAD_PATH='' \
    INPUT_COORDINATES='' \
    INPUT_METADATA='{}' \
    INPUT_VALIDATE_CHECKSUM='false' \
    INPUT_PERMIT_FAIL='false' \
    INPUT_FAIL_FAST='true' \
    INPUT_UPLOAD_ATTEMPTS='3' \
    INPUT_RETRY_DELAY='0' \
    GITHUB_OUTPUT="$work/github_output" \
    GITHUB_STEP_SUMMARY="$work/step_summary" \
    GITHUB_REPOSITORY='example/repo' \
    "$@" \
    bash "$repo_root/scripts/publish.sh" > "$work/out.log" 2>&1 \
    || publish_exit=$?

  if grep -qF "$password" "$work/out.log" "$work/step_summary" \
    "$work/github_output"; then
    fail "password leaked into script output"
  fi
  if grep -q ' auth=no$' "$work/requests.log"; then
    fail "request sent without credentials"
  fi
}

fail() {
  echo "  FAIL: $*"
  failures=$((failures + 1))
}

assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$what: expected '$expected', got '$actual'"
  fi
}

assert_log() {
  if ! grep -qF -- "$1" "$work/out.log"; then
    fail "log lacks: $1"
  fi
}

refute_log() {
  if grep -qF -- "$1" "$work/out.log"; then
    fail "log unexpectedly contains: $1"
  fi
}

output_value() {
  sed -n "s/^$1=//p" "$work/github_output"
}

request_count() {
  grep -cF -- "$1" "$work/requests.log" || true
}

uploaded_paths() {
  sed -E 's/^[A-Z]+ ([^ ]+) .*/\1/' "$work/requests.log"
}

# --- Test cases ---

test_retry_then_success() {
  make_m2repo "$version_dir/$snapshot.jar"
  start_mock "{\"$snapshot.jar\": [\"drop\", 503, 201]}"
  run_publish INPUT_RETRY_DELAY=1
  stop_mock

  assert_eq 0 "$publish_exit" "exit status"
  assert_eq 3 "$(request_count "$snapshot.jar")" "requests for jar"
  assert_eq 1 "$(output_value publication_count)" "publication_count"
  assert_eq 0 "$(output_value failed_count)" "failed_count"
  assert_log "$snapshot.jar: attempt 1/3 failed (curl exit 52:"
  assert_log "empty reply)); retrying in 1s"
  assert_log "$snapshot.jar: attempt 2/3 failed (HTTP 503:"
  assert_log "overloaded)); retrying in 2s"
  assert_log "Uploaded: $snapshot.jar (HTTP 201) after 3 attempts"
}

test_no_retry_on_client_error() {
  make_m2repo "$version_dir/$snapshot.jar"
  start_mock "{\"$snapshot.jar\": [403, 201]}"
  run_publish INPUT_UPLOAD_ATTEMPTS=4
  stop_mock

  assert_eq 1 "$publish_exit" "exit status"
  assert_eq 1 "$(request_count "$snapshot.jar")" "requests for jar"
  assert_eq 1 "$(output_value failed_count)" "failed_count"
  assert_eq "$snapshot.jar" "$(output_value failed_files)" "failed_files"
  assert_log "HTTP Status: 403"
  refute_log "retrying in"
}

test_retries_exhausted() {
  make_m2repo "$version_dir/$snapshot.jar"
  start_mock "{\"$snapshot.jar\": [503]}"
  run_publish INPUT_UPLOAD_ATTEMPTS=3
  stop_mock

  assert_eq 1 "$publish_exit" "exit status"
  assert_eq 3 "$(request_count "$snapshot.jar")" "requests for jar"
  assert_eq 1 "$(output_value failed_count)" "failed_count"
  assert_log "Failed to upload: $snapshot.jar after 3 attempts"
}

# curl can fail after the server has already sent a status; the status
# must still decide (5xx retries, 4xx never does)
test_status_decides_after_transfer_error() {
  make_m2repo "$version_dir/$snapshot.jar"
  start_mock "{\"$snapshot.jar\": [\"partial:503\", 201]}"
  run_publish
  stop_mock
  assert_eq 0 "$publish_exit" "exit status (partial 503)"
  assert_eq 2 "$(request_count "$snapshot.jar")" "requests (partial 503)"
  assert_log "attempt 1/3 failed (curl exit 18:"
  assert_log "after HTTP 503); retrying in 0s"

  start_mock "{\"$snapshot.jar\": [\"partial:403\", 201]}"
  run_publish
  stop_mock
  assert_eq 1 "$publish_exit" "exit status (partial 403)"
  assert_eq 1 "$(request_count "$snapshot.jar")" "requests (partial 403)"
  refute_log "retrying in"
}

# Pin the classification with a curl shim that reports a chosen HTTP
# status and exit code, including exit 56 (otherwise retried) after 403
test_retry_classification() {
  make_m2repo "$version_dir/$snapshot.jar"
  mkdir -p "$work/shim"
  cat > "$work/shim/curl" <<'SHIM'
#!/usr/bin/env bash
echo call >> "$SHIM_LOG"
printf '\n%s' "$SHIM_HTTP"
exit "$SHIM_EXIT"
SHIM
  chmod +x "$work/shim/curl"
  start_mock '{}'
  local case curl_exit http expected
  for case in 56:403:1 7:401:1 18:503:3 0:502:3 56:000:3 6:000:1 0:404:1; do
    IFS=: read -r curl_exit http expected <<< "$case"
    rm -f "$work/shim.log"
    run_publish PATH="$work/shim:$PATH" SHIM_LOG="$work/shim.log" \
      SHIM_HTTP="$http" SHIM_EXIT="$curl_exit"
    assert_eq "$expected" "$(wc -l < "$work/shim.log" | tr -d ' ')" \
      "curl calls (exit $curl_exit, HTTP $http)"
    assert_eq 1 "$publish_exit" "exit status (exit $curl_exit, HTTP $http)"
  done
  stop_mock
}

test_single_attempt_disables_retry() {
  make_m2repo "$version_dir/$snapshot.jar"
  start_mock "{\"$snapshot.jar\": [\"drop\", 201]}"
  run_publish INPUT_UPLOAD_ATTEMPTS=1
  stop_mock

  assert_eq 1 "$publish_exit" "exit status"
  assert_eq 1 "$(request_count "$snapshot.jar")" "requests for jar"
  refute_log "retrying in"
}

test_checksum_upload_retry() {
  rm -rf "$work/raw"
  mkdir -p "$work/raw"
  echo 'raw content' > "$work/raw/file.txt"
  start_mock '{"/file.txt.sha1": [503, 201]}'
  run_publish INPUT_REPOSITORY_FORMAT=raw INPUT_FILES_PATH="$work/raw" \
    INPUT_VALIDATE_CHECKSUM=true
  stop_mock

  assert_eq 0 "$publish_exit" "exit status"
  assert_eq 2 "$(request_count '/file.txt.sha1 ')" "sha1 requests"
  assert_log "file.txt.sha1: attempt 1/3 failed (HTTP 503:"
  assert_log "file.txt.sha1 uploaded after 2 attempts"
  assert_log "Checksums uploaded"
}

test_checksum_retries_exhausted() {
  rm -rf "$work/raw"
  mkdir -p "$work/raw"
  echo 'raw content' > "$work/raw/file.txt"
  start_mock '{"/file.txt.md5": [503]}'
  run_publish INPUT_REPOSITORY_FORMAT=raw INPUT_FILES_PATH="$work/raw" \
    INPUT_VALIDATE_CHECKSUM=true
  stop_mock

  assert_eq 3 "$(request_count '/file.txt.md5 ')" "md5 requests"
  assert_log "file.txt.md5: attempt 2/3 failed (HTTP 503:"
  assert_log "MD5 upload failed for file.txt.md5 (HTTP 503) after 3 attempts"
  assert_log "1/3 checksum uploads failed"
}

test_metadata_uploaded_last() {
  local api_dir='org/example/api/1.0-SNAPSHOT'
  local api='api-1.0-20260925.120000-1'
  make_m2repo \
    "org/example/demo/maven-metadata.xml.sha1" \
    "$version_dir/maven-metadata.xml.sha1" \
    "$version_dir/$snapshot.pom.sha1" \
    "$version_dir/$snapshot.jar.md5" \
    "org/example/api/maven-metadata.xml" \
    "$version_dir/maven-metadata.xml" \
    "$version_dir/$snapshot.jar.asc" \
    "$api_dir/maven-metadata.xml" \
    "$version_dir/$snapshot.jar" \
    "org/example/demo/maven-metadata.xml" \
    "$version_dir/maven-metadata.xml.md5" \
    "$version_dir/$snapshot.pom" \
    "$version_dir/$snapshot.jar.sha1" \
    "$api_dir/$api.jar"
  start_mock '{}'
  # fail_fast off: every metadata file passes the hold-back check
  run_publish INPUT_FAIL_FAST=false
  stop_mock

  local base='/content/repositories/snapshots'
  local expected path
  expected=$(for path in \
    "$api_dir/$api.jar" \
    "$version_dir/$snapshot.jar" \
    "$version_dir/$snapshot.jar.asc" \
    "$version_dir/$snapshot.pom" \
    "$version_dir/$snapshot.jar.md5" \
    "$version_dir/$snapshot.jar.sha1" \
    "$version_dir/$snapshot.pom.sha1" \
    "$api_dir/maven-metadata.xml" \
    "$version_dir/maven-metadata.xml" \
    "$version_dir/maven-metadata.xml.md5" \
    "$version_dir/maven-metadata.xml.sha1" \
    "org/example/api/maven-metadata.xml" \
    "org/example/demo/maven-metadata.xml" \
    "org/example/demo/maven-metadata.xml.sha1"; do
    echo "$base/$path"
  done)

  assert_eq 0 "$publish_exit" "exit status"
  assert_eq "$expected" "$(uploaded_paths)" "upload order"
  assert_eq 14 "$(output_value publication_count)" "publication_count"
  assert_log "Upload order: 4 artefacts, 3 checksums, then 7"
  refute_log "Holding back"
}

test_failed_artefact_withholds_metadata() {
  make_m2repo \
    "$version_dir/maven-metadata.xml" \
    "$version_dir/$snapshot.jar" \
    "$version_dir/$snapshot.pom"
  start_mock "{\"$snapshot.jar\": [403]}"
  run_publish
  stop_mock

  assert_eq 1 "$publish_exit" "exit status"
  assert_eq 0 "$(request_count maven-metadata)" "metadata requests"
  # Fail-fast stops first: metadata counts as skipped, not failed
  assert_eq 1 "$(output_value failed_count)" "failed_count"
  assert_eq "$snapshot.jar" "$(output_value failed_files)" "failed_files"
  assert_log "Skipped files: 2"
  refute_log "Holding back"
}

# Without fail_fast every artefact and checksum is still attempted,
# but no metadata may follow a failure
test_holdback_without_fail_fast() {
  make_m2repo \
    "org/example/demo/maven-metadata.xml" \
    "$version_dir/maven-metadata.xml" \
    "$version_dir/maven-metadata.xml.sha1" \
    "$version_dir/$snapshot.jar" \
    "$version_dir/$snapshot.jar.sha1" \
    "$version_dir/$snapshot.pom"
  start_mock "{\"$snapshot.jar\": [403]}"
  run_publish INPUT_FAIL_FAST=false
  stop_mock

  assert_eq 1 "$publish_exit" "exit status"
  assert_eq 0 "$(request_count maven-metadata)" "metadata requests"
  assert_eq 1 "$(request_count "$snapshot.pom ")" "pom requests"
  assert_eq 1 "$(request_count "$snapshot.jar.sha1 ")" "sha1 requests"
  assert_eq 2 "$(output_value publication_count)" "publication_count"
  assert_eq 4 "$(output_value failed_count)" "failed_count"
  local metadata='maven-metadata.xml,maven-metadata.xml.sha1,maven-metadata.xml'
  assert_eq "$snapshot.jar,$metadata" \
    "$(output_value failed_files)" "failed_files"
  assert_log "Holding back maven-metadata files: 1 earlier upload(s) failed"
  assert_log "Held back: $work/m2repo/$version_dir/maven-metadata.xml"
  assert_log "Metadata held back (counted as failed): 3"
  refute_log "Fail-fast: stopping"
  if ! grep -qF "Metadata held back (counted as failed):** 3" \
    "$work/step_summary"; then
    fail "step summary lacks the held-back count"
  fi
}

# permit_fail keeps the job green, but must not publish metadata
test_holdback_with_permit_fail() {
  make_m2repo \
    "$version_dir/maven-metadata.xml" \
    "$version_dir/$snapshot.jar" \
    "$version_dir/$snapshot.pom.md5"
  start_mock "{\"$snapshot.pom.md5\": [503]}"
  run_publish INPUT_PERMIT_FAIL=true
  stop_mock

  assert_eq 0 "$publish_exit" "exit status"
  assert_eq 0 "$(request_count maven-metadata)" "metadata requests"
  assert_eq 2 "$(output_value failed_count)" "failed_count"
  assert_log "Holding back maven-metadata files"
}

# A failed metadata file must not be followed by its checksums or by
# higher-level metadata
test_failed_metadata_holds_back_rest() {
  make_m2repo \
    "org/example/demo/maven-metadata.xml" \
    "$version_dir/maven-metadata.xml" \
    "$version_dir/maven-metadata.xml.md5" \
    "$version_dir/$snapshot.jar"
  start_mock "{\"$version_dir/maven-metadata.xml\": [400]}"
  run_publish INPUT_FAIL_FAST=false
  stop_mock

  assert_eq 1 "$publish_exit" "exit status"
  assert_eq 1 "$(request_count "$snapshot.jar ")" "jar requests"
  assert_eq 1 "$(request_count maven-metadata)" "metadata requests"
  assert_eq 3 "$(output_value failed_count)" "failed_count"
  assert_log "Metadata held back (counted as failed): 2"
}

test_invalid_retry_inputs() {
  make_m2repo "$version_dir/$snapshot.jar"
  start_mock '{}'
  local value
  for value in 0 1000 -1 2x '' ' '; do
    run_publish INPUT_UPLOAD_ATTEMPTS="$value"
    assert_eq 1 "$publish_exit" "exit status (upload_attempts=$value)"
    assert_log "upload_attempts must be an integer from 1 to 999"
  done
  for value in soon 61 099 -1 1.5 123 '' ' '; do
    run_publish INPUT_RETRY_DELAY="$value"
    assert_eq 1 "$publish_exit" "exit status (retry_delay=$value)"
    assert_log "retry_delay must be an integer from 0 to 60"
  done
  stop_mock
  assert_eq 0 "$(wc -l < "$work/requests.log" | tr -d ' ')" "requests"
}

# Leading zeros are decimal, not octal: 08 would otherwise abort the
# arithmetic and 010 would mean 8 seconds
test_retry_delay_is_decimal() {
  make_m2repo "$version_dir/$snapshot.jar"
  local value expected
  for value in 08 010 0060 000; do
    expected=$((10#$value))
    start_mock '{}'
    run_publish INPUT_RETRY_DELAY="$value" INPUT_UPLOAD_ATTEMPTS=0999
    stop_mock
    assert_eq 0 "$publish_exit" "exit status (retry_delay=$value)"
    assert_log "Upload attempts: 999 (retry delay ${expected}s)"
  done
  # The normalised values drive the retry loop and the backoff
  make_m2repo "$version_dir/$snapshot.jar"
  start_mock "{\"$snapshot.jar\": [503, 201]}"
  run_publish INPUT_RETRY_DELAY=01 INPUT_UPLOAD_ATTEMPTS=02
  stop_mock
  assert_eq 0 "$publish_exit" "exit status (retry after 01s)"
  assert_log "attempt 1/2 failed (HTTP 503:"
  assert_log "retrying in 1s"
}

test_action_passes_retry_inputs() {
  local input
  for input in upload_attempts retry_delay; do
    local env_name="INPUT_${input^^}"
    if ! grep -qF "$env_name: \"\${{ inputs.$input }}\"" \
      "$repo_root/action.yaml"; then
      fail "action.yaml does not map inputs.$input to $env_name"
    fi
  done
}

run_test() {
  current_test="$1"
  local before="$failures"
  echo "▶ $current_test"
  "$current_test"
  if [ "$failures" -eq "$before" ]; then
    echo "  PASS"
  elif [ -f "$work/out.log" ]; then
    sed 's/^/    | /' "$work/out.log"
  fi
}

run_test test_retry_then_success
run_test test_no_retry_on_client_error
run_test test_retries_exhausted
run_test test_status_decides_after_transfer_error
run_test test_retry_classification
run_test test_single_attempt_disables_retry
run_test test_checksum_upload_retry
run_test test_checksum_retries_exhausted
run_test test_metadata_uploaded_last
run_test test_failed_artefact_withholds_metadata
run_test test_holdback_without_fail_fast
run_test test_holdback_with_permit_fail
run_test test_failed_metadata_holds_back_rest
run_test test_invalid_retry_inputs
run_test test_retry_delay_is_decimal
run_test test_action_passes_retry_inputs

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures assertion(s) failed"
  exit 1
fi
echo "✅ All tests passed"
