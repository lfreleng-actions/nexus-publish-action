#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 The Linux Foundation
# SPDX-License-Identifier: Apache-2.0

# Publish artifacts to Nexus Repository
#
# SECURITY NOTES:
# This script implements several defensive security patterns to prevent
# credential leakage in logs, process lists, and debug output:
#
# 1. BRACE SYNTAX FOR TRACE CONTROL: { set +x; } 2>/dev/null
#    - Compound command with comprehensive stderr suppression
#    - More defensive than 'set +x 2>/dev/null' against edge cases
#    - Protects against unexpected diagnostic output from builtins
#
# 2. GLOBAL VARIABLE: local -g nexus_user nexus_pass netrc_file
#    - Creates globals within protected function scope
#    - Ensures atomic initialisation under disabled tracing
#    - Prevents variables from existing in uninitialised state
#
# 3. NETRC FILE: Secure .netrc file with restrictive permissions
#    - Writes credentials to temporary .netrc file once
#    - Uses chmod 600 for file-level security
#    - Automatic cleanup via trap ensures no credential persistence
#
# 4. STDERR SUPPRESSION: 2>/dev/null in curl commands
#    - Deliberate security choice for checksum uploads
#    - Prevents curl error messages from exposing credentials
#
# These patterns prioritise security over simplicity. Do not "optimise"
# without understanding the credential protection implications.

set -euo pipefail

# Input variables (set by action.yaml env: block)
nexus_url="${INPUT_NEXUS_SERVER}"
repo_name="${INPUT_REPOSITORY_NAME}"
repo_format="${INPUT_REPOSITORY_FORMAT}"
files_path="${INPUT_FILES_PATH}"
file_pattern="${INPUT_FILE_PATTERN}"
upload_path="${INPUT_UPLOAD_PATH}"
coordinates="${INPUT_COORDINATES}"
# shellcheck disable=SC2034
metadata="${INPUT_METADATA}"
validate_checksum="${INPUT_VALIDATE_CHECKSUM}"
fail_fast="${INPUT_FAIL_FAST}"
permit_fail="${INPUT_PERMIT_FAIL}"

# Cleanup function to remove .netrc file
# Registered before assign_credentials so a failure during
# credential setup (mktemp, chmod) cannot leak the temp file.
cleanup_credentials() {
  if [ -n "${netrc_file:-}" ] && [ -f "$netrc_file" ]; then
    rm -f "$netrc_file"
  fi
}

trap cleanup_credentials EXIT

# Secure credential assignment function
assign_credentials() {
  local -g nexus_user nexus_pass netrc_file  # See SECURITY NOTES: #2

  # Preserve the current xtrace state so we only restore it
  # if the caller had tracing enabled.  See SECURITY NOTES: #1.
  local _xtrace_was_on=false
  if [[ "$-" == *x* ]]; then _xtrace_was_on=true; fi

  { set +x; } 2>/dev/null  # See SECURITY NOTES: #1
  nexus_user="${INPUT_NEXUS_USERNAME}"
  nexus_pass="${INPUT_NEXUS_PASSWORD}"

  # Create secure .netrc file for credential management
  netrc_file=$(mktemp)
  chmod 600 "$netrc_file"

  # Extract hostname from nexus_url for .netrc machine entry
  local nexus_host
  nexus_host=$(echo "$nexus_url" | \
    sed -E 's|^https?://||' | sed 's|/.*||' | sed 's|:[0-9]*$||')

  # Restore xtrace only if it was previously enabled
  if [ "$_xtrace_was_on" = "true" ]; then
    { set -x; } 2>/dev/null
  fi

  # Default username to the GitHub repository name if not provided
  if [ -z "$nexus_user" ]; then
    nexus_user="${GITHUB_REPOSITORY##*/}"
  fi

  { set +x; } 2>/dev/null  # See SECURITY NOTES: #1
  # Write credentials to .netrc file once
  printf 'machine %s login %s password %s\n' \
    "$nexus_host" "$nexus_user" "$nexus_pass" > "$netrc_file"
  if [ "$_xtrace_was_on" = "true" ]; then
    { set -x; } 2>/dev/null
  fi
}

# Assign credentials securely
assign_credentials

# Remove trailing slash from nexus_url
nexus_url="${nexus_url%/}"

# Function to calculate checksums
calculate_checksums() {
  local file="$1"
  md5sum=$(md5sum "$file" | awk '{print $1}')
  sha1sum=$(sha1sum "$file" | awk '{print $1}')
  sha256sum=$(sha256sum "$file" | awk '{print $1}')
}

# Function to get format-specific upload URL
get_upload_url() {
  local format="$1"
  local filename="$2"
  local coordinates="$3"
  local upload_path="$4"

  case "$format" in
    "maven2_upload")
      if [ -z "$upload_path" ]; then
        echo "Error: maven2_upload requires upload_path" >&2
        return 1
      fi
      local base="${nexus_url}/content/repositories"
      echo "${base}/${repo_name}/${upload_path}"
      ;;
    "maven2")
      local groupId artifactId version group_path base_url
      groupId=$(echo "$coordinates" | \
        sed -n 's/.*groupId=\([^ ]*\).*/\1/p')
      artifactId=$(echo "$coordinates" | \
        sed -n 's/.*artifactId=\([^ ]*\).*/\1/p')
      version=$(echo "$coordinates" | \
        sed -n 's/.*version=\([^ ]*\).*/\1/p')

      if [ -z "$groupId" ] || [ -z "$artifactId" ] || \
        [ -z "$version" ]; then
        echo 'Error: Maven format requires:'
        echo 'groupId, artifactId, and version coordinates'
        return 1
      fi

      group_path=$(echo "$groupId" | tr '.' '/')
      base_url="${nexus_url}/repository/${repo_name}/${group_path}"
      echo "${base_url}/${artifactId}/${version}/${filename}"
      ;;
    "npm")
      local package_name base_url
      # shellcheck disable=SC2001
      package_name=$(echo "$filename" | sed 's/-[0-9].*//')
      base_url="${nexus_url}/repository/${repo_name}/${package_name}"
      echo "${base_url}/-/${filename}"
      ;;
    "pypi")
      local package_name first_letter base_url file_url
      # shellcheck disable=SC2001
      package_name=$(echo "$filename" | sed 's/-[0-9].*//')
      first_letter=$(echo "$package_name" | cut -c1 | \
        tr '[:upper:]' '[:lower:]')
      base_url="${nexus_url}/repository/${repo_name}/packages"
      base_url="${base_url}/source"
      file_url="${base_url}/${first_letter}/${package_name}"
      file_url="${file_url}/${filename}"
      echo "$file_url"
      ;;
    "nuget")
      local package_name version base_url
      package_name=$(echo "$coordinates" | \
        sed -n 's/.*id=\([^ ]*\).*/\1/p')
      version=$(echo "$coordinates" | \
        sed -n 's/.*version=\([^ ]*\).*/\1/p')
      if [ -z "$package_name" ] || [ -z "$version" ]; then
        # shellcheck disable=SC2001
        package_name=$(echo "$filename" | sed 's/\.[0-9].*//')
        version=$(echo "$filename" | \
          sed -n 's/.*\.\([0-9][0-9.]*\)\.nupkg/\1/p')
      fi
      base_url="${nexus_url}/repository/${repo_name}/${package_name}"
      echo "${base_url}/${version}/${filename}"
      ;;
    "helm")
      local base_url
      if [ -n "$upload_path" ]; then
        upload_path=$(echo "$upload_path" | sed 's|^/||; s|/$||')
        base_url="${nexus_url}/repository/${repo_name}/${upload_path}"
        echo "${base_url}/${filename}"
      else
        echo "${nexus_url}/repository/${repo_name}/${filename}"
      fi
      ;;
    "docker")
      echo 'Error: Docker format requires special handling'
      echo '       with registry API'
      return 1
      ;;
    *)
      local base_url
      if [ -n "$upload_path" ]; then
        upload_path=$(echo "$upload_path" | sed 's|^/||; s|/$||')
        base_url="${nexus_url}/repository/${repo_name}/${upload_path}"
        echo "${base_url}/${filename}"
      else
        echo "${nexus_url}/repository/${repo_name}/${filename}"
      fi
      ;;
  esac
}

# --- Secure credential handling functions ---

secure_upload_file() {
  local file="$1"
  local upload_url="$2"
  local content_type="${3:-application/octet-stream}"

  # NOTE: -f flag deliberately omitted so that the Nexus
  # response body is captured on HTTP errors (4xx/5xx).
  # The \n before %{http_code} ensures the status code starts on
  # its own line even when the response body lacks a trailing newline.
  curl -s --max-redirs 0 -w '\n%{http_code}' \
    --connect-timeout 30 --max-time 300 \
    --netrc-file "$netrc_file" \
    -H "Content-Type: $content_type" \
    --upload-file "$file" \
    "$upload_url" \
    2>&1
}

# Returns 0 on success, 1 on failure; prints diagnostics
secure_upload_checksum() {
  local checksum_value="$1"
  local checksum_url="$2"
  local checksum_type="${3:-checksum}"

  local ck_resp ck_exit ck_http
  if ck_resp=$(printf '%s' "$checksum_value" | curl -s \
    --connect-timeout 10 --max-time 30 \
    -w '%{http_code}' \
    --netrc-file "$netrc_file" \
    --data-binary @- \
    "$checksum_url" \
    2>/dev/null); then  # See SECURITY NOTES: #4
    ck_exit=0
  else
    ck_exit=$?
  fi

  ck_http="${ck_resp: -3}"
  if [ $ck_exit -ne 0 ]; then
    echo "  ⚠️  ${checksum_type} upload failed (curl exit $ck_exit)"
    return 1
  elif ! [[ "$ck_http" =~ ^2[0-9][0-9]$ ]]; then
    echo "  ⚠️  ${checksum_type} upload failed (HTTP $ck_http)"
    return 1
  fi
  return 0
}

secure_upload_pypi() {
  local file="$1"
  local upload_url="$2"

  # See secure_upload_file for \n%{http_code} rationale.
  curl -s --max-redirs 0 -w '\n%{http_code}' \
    --connect-timeout 30 --max-time 300 \
    --netrc-file "$netrc_file" \
    -F "content=@${file}" \
    "$upload_url" \
    2>&1
}

perform_secure_upload() {
  local file="$1"
  local upload_url="$2"
  local format="$3"

  (
    set +x 2>/dev/null
    case "$format" in
      "maven2"|"maven2_upload")
        secure_upload_file "$file" "$upload_url" \
          "application/octet-stream"
        ;;
      "npm")
        secure_upload_file "$file" "$upload_url" \
          "application/x-compressed"
        ;;
      "pypi")
        secure_upload_pypi "$file" "$upload_url"
        ;;
      *)
        secure_upload_file "$file" "$upload_url"
        ;;
    esac
  )
}

# --- Error formatting functions ---

format_http_error() {
  local http_code="$1"
  case "$http_code" in
    400) echo "Repository is read-only or malformed request" ;;
    401) echo "Authentication failed: invalid credentials" ;;
    403) echo "Authorisation denied: insufficient permissions" ;;
    404) echo "Repository or upload path not found" ;;
    405) echo "HTTP method not allowed by this endpoint" ;;
    413) echo "File too large for the server to accept" ;;
    500) echo "Nexus internal server error" ;;
    502) echo "Bad gateway (proxy in front of Nexus?)" ;;
    503) echo "Nexus unavailable (starting up or overloaded)" ;;
    504) echo "Gateway timeout reaching Nexus" ;;
    5[0-9][0-9]) echo "Nexus server error ($http_code)" ;;
    *)   echo "Unexpected HTTP status: $http_code" ;;
  esac
}

format_curl_error() {
  local exit_code="$1"
  case "$exit_code" in
    5)  echo "Could not resolve proxy" ;;
    6)  echo "DNS resolution failed: could not resolve host" ;;
    7)  echo "Connection refused or could not connect" ;;
    22) echo "HTTP error (server returned an error page)" ;;
    26) echo "Read error on local file" ;;
    28) echo "Operation timed out" ;;
    35) echo "SSL/TLS handshake failed" ;;
    47) echo "Too many redirects" ;;
    52) echo "Server returned nothing (empty reply)" ;;
    55) echo "Network send error" ;;
    56) echo "Network receive error" ;;
    *)  echo "curl failed with exit code: $exit_code" ;;
  esac
}

# Extract a diagnostic from a Nexus response body.
# Tries Nexus 2.x XML, Nexus 3.x JSON, then truncated fallback.
# Uses printf instead of echo to handle bodies starting with -n etc.
extract_nexus_message() {
  local body="$1"
  local msg

  msg=$(printf '%s' "$body" | \
    sed -n 's/.*<msg>\(.*\)<\/msg>.*/\1/p' | head -n 1)
  if [ -n "$msg" ]; then echo "$msg"; return; fi

  msg=$(printf '%s' "$body" | \
    sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)
  if [ -n "$msg" ]; then echo "$msg"; return; fi

  if [ -n "$body" ]; then
    echo "${body:0:200}"
  fi
}

# --- Main upload function ---

upload_file() {
  local file="$1"
  local filename
  filename=$(basename "$file")

  echo "🔍 Processing: $filename for format: $repo_format"

  if [ "$validate_checksum" = "true" ]; then
    calculate_checksums "$file"
    echo "  MD5: $md5sum"
    echo "  SHA1: $sha1sum"
    echo "  SHA256: $sha256sum"
  fi

  local effective_upload_path="$upload_path"
  if [ "$repo_format" = "maven2_upload" ]; then
    local files_root="${files_path%/}"
    local rel_path="${file#"${files_root}"/}"
    if [ "$rel_path" = "$file" ]; then
      echo "❌ File $file is not under files_path $files_root"
      return 1
    fi
    effective_upload_path="$rel_path"
  fi

  local upload_url
  if ! upload_url=$(get_upload_url "$repo_format" \
    "$filename" "$coordinates" "$effective_upload_path"); then
    echo "❌ Failed to determine upload URL for $filename"
    return 1
  fi

  echo "📤 Uploading: $filename"
  echo "   Format: $repo_format"
  echo "   Repository: $repo_name"
  echo "   URL: $upload_url"

  local response http_code response_body curl_exit_code
  if response=$(perform_secure_upload \
    "$file" "$upload_url" "$repo_format"); then
    curl_exit_code=0
  else
    curl_exit_code=$?
  fi

  http_code=$(echo "$response" | tail -n 1)
  response_body=$(echo "$response" | sed '$d')

  # Network / transport-level failure
  if [ "$curl_exit_code" -ne 0 ]; then
    local curl_reason
    curl_reason=$(format_curl_error "$curl_exit_code")
    echo "   ❌ Failed to upload: $filename"
    echo "   Reason: $curl_reason"
    echo "   curl exit code: $curl_exit_code"
    if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
      echo "   HTTP Status: $http_code"
    fi
    if [ -n "$response_body" ]; then
      echo "   Response: ${response_body:0:500}"
    fi
    echo "   Target: $upload_url"
    return 1
  fi

  # HTTP-level success (2xx)
  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    if echo "$response_body" | grep -qi '<html>'; then
      echo "   ❌ Failed to upload: $filename"
      echo "   HTTP $http_code returned HTML error page"
      local nexus_msg
      nexus_msg=$(extract_nexus_message "$response_body")
      if [ -n "$nexus_msg" ]; then
        echo "   Nexus message: $nexus_msg"
      fi
      echo "   Target: $upload_url"
      return 1
    fi

    echo "   ✅ Uploaded: $filename (HTTP $http_code)"

    if [ "$validate_checksum" = "true" ] &&
       [[ "$repo_format" =~ ^(maven2|raw)$ ]]; then
      local ck_failures=0
      secure_upload_checksum "$md5sum" \
        "${upload_url}.md5" "MD5" || \
        ck_failures=$((ck_failures + 1))
      secure_upload_checksum "$sha1sum" \
        "${upload_url}.sha1" "SHA1" || \
        ck_failures=$((ck_failures + 1))
      secure_upload_checksum "$sha256sum" \
        "${upload_url}.sha256" "SHA256" || \
        ck_failures=$((ck_failures + 1))
      if [ "$ck_failures" -eq 0 ]; then
        echo '  📋 Checksums uploaded'
      else
        echo "  ⚠️  $ck_failures/3 checksum uploads failed"
      fi
    fi

    return 0
  fi

  # HTTP-level failure (non-2xx)
  local http_reason nexus_msg
  http_reason=$(format_http_error "$http_code")
  nexus_msg=$(extract_nexus_message "$response_body")

  echo "   ❌ Failed to upload: $filename"
  echo "   HTTP Status: $http_code — $http_reason"
  if [ -n "$nexus_msg" ]; then
    echo "   Nexus message: $nexus_msg"
  elif [ -n "$response_body" ]; then
    echo "   Response: ${response_body:0:500}"
  fi
  echo "   Target: $upload_url"
  return 1
}

# NOTE: cleanup_credentials and its trap are registered near the
# top of the script (before assign_credentials) so that a failure
# during credential setup cannot leak the temp .netrc file.

# Prepare upload path
if [ -n "$upload_path" ]; then
  upload_path=$(echo "$upload_path" | sed 's|^/||; s|/$||')
  if [ -n "$upload_path" ]; then
    upload_path="/${upload_path}"
  fi
fi

published_files=""
failed_files=""
publication_count=0
failed_count=0
skipped_fail_fast=0

echo '🚀 Starting Nexus Publishing/Upload'
echo '📋 Configuration:'
echo "   Server: $nexus_url"
echo "   Repository: $repo_name"
echo "   Format: $repo_format"
echo "   Files path: $files_path"
echo "   File pattern: $file_pattern"
if [ -n "$upload_path" ]; then
  echo "   Upload path: $upload_path"
fi
if [ -n "$coordinates" ]; then
  echo "   Coordinates: $coordinates"
fi
echo "   Permit fail: $permit_fail"
echo "   Fail fast: $fail_fast"

# Find files
declare -a target_files=()

if [ -f "$files_path" ]; then
  if [ "$repo_format" = "maven2_upload" ]; then
    echo 'Error: maven2_upload requires files_path to be' \
      'a directory, not a single file ❌'
    exit 1
  fi
  target_files=("$files_path")
elif [ -d "$files_path" ]; then
  if [ "$file_pattern" = "*" ]; then
    readarray -d '' target_files < <(find "$files_path" \
      -type f -print0)
  else
    readarray -d '' target_files < <(find "$files_path" \
      -name "$file_pattern" -type f -print0)
  fi
else
  echo 'Error: Invalid files_path; must be file or directory ❌'
  exit 1
fi

if [ ${#target_files[@]} -eq 0 ]; then
  echo "Warning: no files found matching pattern $file_pattern ⚠️"
  echo "Path: $files_path"
  {
    echo 'published_files='
    echo 'failed_files='
    echo 'publication_count=0'
    echo 'failed_count=0'
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

echo 'Found files to publish 📦'
printf '%s\n' "${target_files[@]}"
echo ""

# Upload each file. processed_count tracks the loop position
# (incremented for every iteration, including skips) so that
# fail-fast can compute remaining work without conflating
# the success/failure counts with earlier non-existent skips.
processed_count=0
for target_file in "${target_files[@]}"; do
  processed_count=$((processed_count + 1))
  if [ ! -f "$target_file" ]; then
    echo "Skipping non-existent file: $target_file ⚠️"
    continue
  fi

  if upload_file "$target_file"; then
    filename=$(basename "$target_file")
    if [ -z "$published_files" ]; then
      published_files="$filename"
    else
      published_files="$published_files,$filename"
    fi
    publication_count=$((publication_count + 1))
  else
    filename=$(basename "$target_file")
    if [ -z "$failed_files" ]; then
      failed_files="$filename"
    else
      failed_files="$failed_files,$filename"
    fi
    failed_count=$((failed_count + 1))

    # Fail-fast: stop on first failure when enabled and
    # failures are not permitted
    if [ "$fail_fast" = "true" ] && \
       [ "$permit_fail" != "true" ]; then
      skipped_fail_fast=0
      # Slice from processed_count (the loop has consumed that
      # many entries already, including any non-existent skips).
      # Only count files still on disk so vanished entries are
      # not misattributed to fail-fast.
      for _remaining_file in \
        "${target_files[@]:$processed_count}"; do
        if [ -f "$_remaining_file" ]; then
          skipped_fail_fast=$((skipped_fail_fast + 1))
        fi
      done
      echo ""
      echo "🛑 Fail-fast: stopping after first failure"
      echo "   Set fail_fast: 'false' to attempt all files"
      if [ "$skipped_fail_fast" -gt 0 ]; then
        echo "   Skipped files: $skipped_fail_fast"
      fi
      break
    fi
  fi
  echo ""
done

total_found=${#target_files[@]}

echo '📊 Publication Summary:'
echo "  - Total files found: $total_found"
echo "  - Successfully published: $publication_count"
echo "  - Failed uploads: $failed_count"
if [ "$skipped_fail_fast" -gt 0 ]; then
  echo "  - Skipped (fail-fast): $skipped_fail_fast"
fi
echo "  - Repository format: $repo_format"
echo "  - Published files: $published_files"
if [ "$failed_count" -gt 0 ]; then
  echo "  - Failed files: $failed_files"
fi

# Set outputs
{
  echo "published_files=$published_files"
  echo "failed_files=$failed_files"
  echo "publication_count=$publication_count"
  echo "failed_count=$failed_count"
} >> "$GITHUB_OUTPUT"

# Step summary
{
  echo '## 📦 Nexus Publisher'
  echo "- **Server:** $nexus_url"
  echo "- **Repository:** $repo_name"
  echo "- **Repository format:** $repo_format"
  echo "- **Files path:** $files_path"
  if [ -n "$upload_path" ]; then
    echo "- **Upload path:** $upload_path"
  fi
  echo "- **Total files found:** $total_found"
  echo "- **Total files published:** $publication_count"
  echo "- **Failed uploads:** $failed_count"
  if [ "$skipped_fail_fast" -gt 0 ]; then
    echo "- **Skipped (fail-fast):** $skipped_fail_fast"
  fi
  if [ "$publication_count" -gt 0 ]; then
    echo "- **Published files:** $published_files"
  fi
  if [ "$failed_count" -gt 0 ]; then
    echo "- **Failed files:** $failed_files"
  fi

  # Exit logic (summary messages)
  if [ "$failed_count" -gt 0 ] && \
     [ "$permit_fail" = "true" ]; then
    echo 'Some uploads failed; for details check job output ⚠️'
  elif [ "$failed_count" -gt 0 ] && \
       [ "$permit_fail" != "true" ]; then
    echo 'Some uploads failed; for details check job output ❌'
  else
    echo "### All content published successfully 🎉"
  fi
} >> "$GITHUB_STEP_SUMMARY"

# Exit logic
if [ "$failed_count" -gt 0 ] && \
   [ "$permit_fail" != "true" ]; then
  exit 1
fi
