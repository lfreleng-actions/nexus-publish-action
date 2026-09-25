#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Tests for scripts/publish.sh Nexus 3 maven2_upload paths and dry-run
# mode. A curl shim placed first on PATH records every invocation, so the
# tests need no server and can prove a dry run never calls curl.
# Requires bash 4.4+.
#
# Usage: bash tests/test_nexus3_dry_run.sh

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
publish_exit=0
failures=0

# Distinctive value so any leak into logs or outputs is detectable
password='shim-secret-4b7d2a'

server='https://nexus.example.org'
version_dir='org/example/demo/1.0-SNAPSHOT'
snapshot='demo-1.0-20260925.120000-1'

trap 'rm -rf "$work"' EXIT

# The shim logs the target URL (curl's last argument) and reports
# HTTP 201, matching the '\n%{http_code}' write-out publish.sh uses.
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >> "$CURL_SHIM_LOG"
printf '\n201'
SHIM
chmod +x "$work/bin/curl"

# publish.sh calls mktemp only to create the .netrc file, so a shim
# that logs each call shows whether credentials were ever written
real_mktemp=$(command -v mktemp)
cat > "$work/bin/mktemp" <<SHIM
#!/usr/bin/env bash
echo called >> "\$MKTEMP_SHIM_LOG"
exec "$real_mktemp" "\$@"
SHIM
chmod +x "$work/bin/mktemp"

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
  rm -f "$work/curl.log" "$work/mktemp.log"
  : > "$work/github_output"
  : > "$work/step_summary"
  publish_exit=0
  env \
    PATH="$work/bin:$PATH" \
    CURL_SHIM_LOG="$work/curl.log" \
    MKTEMP_SHIM_LOG="$work/mktemp.log" \
    INPUT_NEXUS_SERVER="$server" \
    INPUT_NEXUS_USERNAME='shim-user' \
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

assert_no_curl() {
  if [ -e "$work/curl.log" ]; then
    fail "curl was invoked: $(tr '\n' ' ' < "$work/curl.log")"
  fi
}

assert_no_netrc() {
  if [ -e "$work/mktemp.log" ]; then
    fail "a .netrc file was created"
  fi
}

output_value() {
  sed -n "s/^$1=//p" "$work/github_output"
}

curl_urls() {
  if [ -e "$work/curl.log" ]; then
    LC_ALL=C sort "$work/curl.log"
  fi
}

# --- Test cases ---

test_nexus3_upload_paths() {
  make_m2repo "$version_dir/$snapshot.jar" "$version_dir/$snapshot.pom"
  run_publish INPUT_NEXUS_VERSION=3

  local base="$server/repository/snapshots/$version_dir"
  assert_eq 0 "$publish_exit" "exit status"
  assert_eq "$(printf '%s\n' "$base/$snapshot.jar" "$base/$snapshot.pom")" \
    "$(curl_urls)" "upload URLs"
  assert_eq 2 "$(output_value publication_count)" "publication_count"
  assert_eq 0 "$(output_value dry_run_count)" "dry_run_count"
}

test_nexus2_paths_by_default() {
  make_m2repo "$version_dir/$snapshot.jar"
  run_publish

  assert_eq 0 "$publish_exit" "exit status"
  assert_eq "$server/content/repositories/snapshots/$version_dir/$snapshot.jar" \
    "$(curl_urls)" "upload URL"
  # A live run writes .netrc, proving the mktemp shim is on PATH
  if [ ! -e "$work/mktemp.log" ]; then
    fail "live run did not create .netrc via the mktemp shim"
  fi
}

test_nexus3_with_upload_path_prefix() {
  make_m2repo "demo/1.0-SNAPSHOT/$snapshot.jar"
  run_publish INPUT_NEXUS_VERSION=3 INPUT_UPLOAD_PATH=/org/example/
  assert_eq 0 "$publish_exit" "exit status"
  assert_eq "$server/repository/snapshots/$version_dir/$snapshot.jar" \
    "$(curl_urls)" "upload URL"
}

test_other_formats_ignore_nexus_version() {
  rm -rf "$work/raw"
  mkdir -p "$work/raw"
  echo 'raw content' > "$work/raw/file.txt"
  run_publish INPUT_REPOSITORY_FORMAT=raw INPUT_FILES_PATH="$work/raw" \
    INPUT_NEXUS_VERSION=2
  assert_eq 0 "$publish_exit" "exit status"
  assert_eq "$server/repository/snapshots/file.txt" "$(curl_urls)" \
    "raw upload URL"
}

test_invalid_nexus_version() {
  make_m2repo "$version_dir/$snapshot.jar"
  local value
  for value in 4 '' ' ' v3; do
    run_publish INPUT_NEXUS_VERSION="$value"
    assert_eq 1 "$publish_exit" "exit status (nexus_version='$value')"
    assert_log "nexus_version must be '2' or '3', not '$value'"
    assert_no_curl
    assert_no_netrc
  done
}

test_dry_run_makes_no_requests() {
  make_m2repo \
    "$version_dir/$snapshot.jar" \
    "$version_dir/$snapshot.jar.sha1" \
    "$version_dir/maven-metadata.xml"
  run_publish INPUT_DRY_RUN=true INPUT_NEXUS_VERSION=3

  local base="$server/repository/snapshots/$version_dir"
  assert_eq 0 "$publish_exit" "exit status"
  assert_no_curl
  assert_eq 3 "$(output_value dry_run_count)" "dry_run_count"
  assert_eq 0 "$(output_value publication_count)" "publication_count"
  assert_eq "" "$(output_value published_files)" "published_files"
  assert_eq 0 "$(output_value failed_count)" "failed_count"
  assert_log "Would upload: $snapshot.jar"
  assert_log "URL: $base/$snapshot.jar"
  assert_log "URL: $base/maven-metadata.xml"
  assert_log "Dry run, would publish: 3"
  if ! grep -qF 'Dry run complete; nothing uploaded' "$work/step_summary"; then
    fail "step summary lacks dry-run result"
  fi
  if grep -qF 'published successfully' "$work/step_summary"; then
    fail "dry-run step summary claims content was published"
  fi
}

test_dry_run_needs_no_credentials() {
  make_m2repo "$version_dir/$snapshot.jar"
  run_publish INPUT_DRY_RUN=true INPUT_NEXUS_PASSWORD='' \
    INPUT_NEXUS_USERNAME=''
  assert_eq 0 "$publish_exit" "exit status"
  assert_no_curl
  assert_no_netrc
  assert_eq 1 "$(output_value dry_run_count)" "dry_run_count"
}

# dry_run is a safety boundary: a typo must never select a live upload
test_dry_run_rejects_other_values() {
  make_m2repo "$version_dir/$snapshot.jar"
  local value
  for value in ttrue truee yes 1 on 'true!' '' ' '; do
    run_publish INPUT_DRY_RUN="$value"
    assert_eq 1 "$publish_exit" "exit status (dry_run='$value')"
    assert_log "dry_run must be 'true' or 'false', not '$value'"
    assert_no_curl
    assert_no_netrc
  done
}

test_dry_run_ignores_case_and_whitespace() {
  make_m2repo "$version_dir/$snapshot.jar"
  local value
  for value in TRUE True ' true' $'true\n'; do
    run_publish INPUT_DRY_RUN="$value"
    assert_eq 0 "$publish_exit" "exit status (dry_run='$value')"
    assert_no_curl
    assert_no_netrc
    assert_eq 1 "$(output_value dry_run_count)" "dry_run_count"
  done
  for value in FALSE ' false '; do
    run_publish INPUT_DRY_RUN="$value"
    assert_eq 0 "$publish_exit" "exit status (dry_run='$value')"
    assert_eq 1 "$(output_value publication_count)" "publication_count"
    assert_eq 0 "$(output_value dry_run_count)" "dry_run_count"
  done
}

test_live_run_requires_password() {
  make_m2repo "$version_dir/$snapshot.jar"
  run_publish INPUT_DRY_RUN=false INPUT_NEXUS_PASSWORD=''
  assert_eq 1 "$publish_exit" "exit status"
  assert_log "a live run needs nexus_password (dry_run is false)"
  assert_no_curl
  assert_no_netrc
}

# Run the action.yaml 'Validate inputs' step script with the given
# NAME=value environment. Sets publish_exit and writes out.log.
run_validate_step() {
  awk '
    /^      id: validate$/ { in_step = 1 }
    in_step && /^      run: \|$/ { in_run = 1; next }
    in_run && /^    - name:/ { exit }
    in_run { sub(/^        /, ""); print }
  ' "$repo_root/action.yaml" > "$work/validate.sh"
  publish_exit=0
  env \
    INPUT_NEXUS_SERVER="$server" \
    INPUT_NEXUS_PASSWORD="$password" \
    INPUT_REPOSITORY_NAME='snapshots' \
    INPUT_FILES_PATH="$work" \
    INPUT_REPOSITORY_FORMAT='maven2_upload' \
    INPUT_DRY_RUN='false' \
    "$@" \
    bash -e "$work/validate.sh" > "$work/out.log" 2>&1 || publish_exit=$?
}

test_action_validate_step() {
  run_validate_step
  if ! grep -q "dry_run must be" "$work/validate.sh"; then
    fail "could not extract the validate step from action.yaml"
    return
  fi
  assert_eq 0 "$publish_exit" "exit status (live, password)"
  run_validate_step INPUT_DRY_RUN=TRUE INPUT_NEXUS_PASSWORD=''
  assert_eq 0 "$publish_exit" "exit status (dry run, no password)"
  run_validate_step INPUT_NEXUS_PASSWORD=''
  assert_eq 1 "$publish_exit" "exit status (live, no password)"
  assert_log "a live run needs nexus_password (dry_run is false)"
  local value
  for value in ttrue ''; do
    run_validate_step INPUT_DRY_RUN="$value" INPUT_NEXUS_PASSWORD=''
    assert_eq 1 "$publish_exit" "exit status (dry_run='$value')"
    assert_log "dry_run must be 'true' or 'false', not '$value'"
  done

  # The metadata must not demand a password a dry run does not need
  if ! awk '/^  nexus_password:$/ { f = 1; next }
            f && /^  [a-z]/ { exit }
            f && /^    required: false$/ { found = 1 }
            END { exit !found }' "$repo_root/action.yaml"; then
    fail "action.yaml nexus_password is not required: false"
  fi
}

test_dry_run_lists_checksums() {
  rm -rf "$work/raw"
  mkdir -p "$work/raw"
  echo 'raw content' > "$work/raw/file.txt"
  run_publish INPUT_DRY_RUN=true INPUT_REPOSITORY_FORMAT=raw \
    INPUT_FILES_PATH="$work/raw" INPUT_VALIDATE_CHECKSUM=true
  assert_eq 0 "$publish_exit" "exit status"
  assert_no_curl
  assert_log "Checksums: $server/repository/snapshots/file.txt.{md5,sha1,sha256}"
}

test_dry_run_reports_url_errors() {
  rm -rf "$work/raw"
  mkdir -p "$work/raw"
  echo 'jar content' > "$work/raw/app.jar"
  run_publish INPUT_DRY_RUN=true INPUT_REPOSITORY_FORMAT=maven2 \
    INPUT_FILES_PATH="$work/raw"
  assert_eq 1 "$publish_exit" "exit status"
  assert_no_curl
  assert_eq 1 "$(output_value failed_count)" "failed_count"
  assert_eq 0 "$(output_value dry_run_count)" "dry_run_count"
  local summary
  summary=$(grep -E '^### |Some uploads failed' "$work/step_summary")
  assert_eq "$(printf '%s\n' \
    '### Dry run complete; nothing uploaded 🧪' \
    'Some uploads failed; for details check job output ❌')" \
    "$summary" "step summary result lines"
}

test_dry_run_with_no_files() {
  rm -rf "$work/m2repo"
  mkdir -p "$work/m2repo"
  run_publish INPUT_DRY_RUN=true
  assert_eq 0 "$publish_exit" "exit status"
  assert_no_curl
  assert_eq 0 "$(output_value dry_run_count)" "dry_run_count"
  if ! grep -qF 'Dry run complete; nothing uploaded' "$work/step_summary"; then
    fail "step summary lacks dry-run result"
  fi
}

test_action_wiring() {
  local input
  for input in nexus_version dry_run; do
    local env_name="INPUT_${input^^}"
    if ! grep -qF "$env_name: \"\${{ inputs.$input }}\"" \
      "$repo_root/action.yaml"; then
      fail "action.yaml does not map inputs.$input to $env_name"
    fi
  done
  if ! grep -qF 'steps.publish.outputs.dry_run_count' \
    "$repo_root/action.yaml"; then
    fail "action.yaml does not expose the dry_run_count output"
  fi
}

run_test() {
  local before="$failures"
  echo "▶ $1"
  "$1"
  if [ "$failures" -eq "$before" ]; then
    echo "  PASS"
  elif [ -f "$work/out.log" ]; then
    sed 's/^/    | /' "$work/out.log"
  fi
}

run_test test_nexus3_upload_paths
run_test test_nexus2_paths_by_default
run_test test_nexus3_with_upload_path_prefix
run_test test_other_formats_ignore_nexus_version
run_test test_invalid_nexus_version
run_test test_dry_run_makes_no_requests
run_test test_dry_run_needs_no_credentials
run_test test_dry_run_rejects_other_values
run_test test_dry_run_ignores_case_and_whitespace
run_test test_live_run_requires_password
run_test test_dry_run_lists_checksums
run_test test_dry_run_reports_url_errors
run_test test_dry_run_with_no_files
run_test test_action_wiring
run_test test_action_validate_step

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures assertion(s) failed"
  exit 1
fi
echo "✅ All tests passed"
