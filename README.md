<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 📦 Nexus Publishing Action

Publishes content to Sonatype Nexus Repository servers.

## nexus-publish-action

## Features

- **Universal Support**: Works with all major Nexus repository formats
- **Format-Aware Uploads**: Automatically handles format-specific upload paths
  and metadata
- **Checksum Validation**: Optional MD5, SHA1, and SHA256 checksum generation
  and upload
- **Flexible File Selection**: Upload single files, directories, or files
  matching patterns
- **Comprehensive Logging**: Detailed upload progress and summary reporting
- **Nexus-Aware Error Handling**: Actionable diagnostics for HTTP status codes
  (401 invalid credentials, 403 permission denied, 404 repository not found,
  etc.) with Nexus response body extraction for both XML and JSON error formats
- **Fail-Fast Support**: Configurable stop-on-first-failure mode to shorten
  feedback loops when uploading large file sets
- **Network Error Diagnostics**: Human-readable messages for connection,
  timeout, DNS, and SSL/TLS failures

## Supported Repository Formats

<!-- markdownlint-enable MD013 -->

| Format          | Description             | Example Files                |
| --------------- | ----------------------- | ---------------------------- |
| `raw`           | Generic binary files    | `*.zip`, `*.tar.gz`, `*.bin` |
| `maven2`        | Java artifacts          | `*.jar`, `*.war`, `*.pom`    |
| `maven2_upload` | Maven m2repo trees      | Pre-built `m2repo/` dirs     |
| `npm`           | Node.js packages        | `*.tgz`                      |
| `docker`        | Container images        | N/A (registry API)           |
| `helm`          | Kubernetes charts       | `*.tgz`                      |
| `pypi`          | Python packages         | `*.whl`, `*.tar.gz`          |
| `nuget`         | .NET packages           | `*.nupkg`                    |
| `rubygems`      | Ruby gems               | `*.gem`                      |
| `apt`           | Debian packages         | `*.deb`                      |
| `yum`/`rpm`     | Red Hat packages        | `*.rpm`                      |
| `composer`      | PHP packages            | `*.zip`                      |
| `conan`         | C/C++ packages          | `*.tgz`                      |
| `conda`         | Multi-language packages | `*.tar.bz2`                  |
| `r`             | R packages              | `*.tar.gz`                   |
| `go`            | Go modules              | `*.zip`                      |
| `p2`            | Eclipse plugins         | `*.jar`                      |
| `gitlfs`        | Git LFS objects         | Any large files              |
| `cocoapods`     | iOS/macOS packages      | `*.tar.gz`                   |
| `bower`         | Frontend packages       | `*.tar.gz`                   |

<!-- markdownlint-enable MD013 -->

## Usage Examples

### Raw Files Upload

```yaml
- name: Upload Raw Files
  uses: ./.github/actions/nexus-publish-action
  with:
    nexus_server: "https://nexus.example.com"
    nexus_username: "admin"
    nexus_password: ${{ secrets.NEXUS_PASSWORD }}
    repository_format: "raw"
    repository_name: "raw-files"
    files_path: "./dist"
    file_pattern: "*.zip"
    upload_path: "releases/v1.0.0"
```

### Maven Artifacts

```yaml
- name: Upload Maven Artifacts
  uses: ./.github/actions/nexus-publish-action
  with:
    nexus_server: "https://nexus.example.com"
    nexus_password: ${{ secrets.NEXUS_PASSWORD }}
    repository_format: "maven2"
    repository_name: "maven-releases"
    files_path: "./target/myapp-1.0.0.jar"
    coordinates: "groupId=com.example artifactId=myapp version=1.0.0"
```

### Helm Charts

```yaml
- name: Upload Helm Charts
  uses: ./.github/actions/nexus-publish-action
  with:
    nexus_server: "https://nexus.example.com"
    nexus_password: ${{ secrets.NEXUS_PASSWORD }}
    repository_format: "helm"
    repository_name: "helm-charts"
    files_path: "./charts"
    file_pattern: "*.tgz"
```

### Maven m2repo Upload (Nexus 2.x)

```yaml
- name: Upload Maven m2repo to Nexus 2.x
  uses: ./.github/actions/nexus-publish-action
  with:
    nexus_server: "https://nexus.example.com"
    nexus_username: ${{ secrets.NEXUS_USERNAME }}
    nexus_password: ${{ secrets.NEXUS_PASSWORD }}
    repository_format: "maven2_upload"
    repository_name: "maven-snapshots"
    files_path: "${{ github.workspace }}/m2repo"
    permit_fail: "false"
```

## Inputs

### Required

<!-- markdownlint-disable MD013 -->

| Name                | Description                                          |
| ------------------- | ---------------------------------------------------- |
| `nexus_server`      | Nexus server URL (e.g., `https://nexus.example.com`) |
| `nexus_password`    | Nexus password for authentication                    |
| `repository_format` | Repository format (see supported formats above)      |
| `repository_name`   | Nexus repository name                                |
| `files_path`        | Path to files directory or specific file to upload   |

<!-- markdownlint-enable MD013 -->

### Optional

<!-- markdownlint-disable MD013 -->

| Name                | Description                                            | Default          |
| ------------------- | ------------------------------------------------------ | ---------------- |
| `nexus_username`    | Nexus username for authentication                      | GitHub Repo Name |
| `file_pattern`      | File pattern to match when `files_path` is a directory | `*`              |
| `upload_path`       | Path within repository for uploads (format-specific)   | `""`             |
| `coordinates`       | Artifact coordinates (format-specific)                 | `""`             |
| `metadata`          | Metadata as JSON string                                | `"{}"`           |
| `validate_checksum` | Generate and upload checksums                          | `true`           |
| `permit_fail`       | Do not exit/error when some content fails to upload    | `false`          |
| `fail_fast`         | Stop on first failure (when `permit_fail` is `false`)  | `true`           |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Name                | Description                             |
| ------------------- | --------------------------------------- |
| `published_files`   | Comma-separated list of published files |
| `publication_count` | Number of files published               |
| `failed_count`      | Number of files that failed to publish  |
| `failed_files`      | Comma-separated list of failed files    |

<!-- markdownlint-enable MD013 -->

## Format-Specific Details

### Maven2

- **Coordinates required**: `groupId=com.example artifactId=myapp version=1.0.0`
- **Optional coordinates**: `classifier=sources`, `packaging=jar`
- **Upload path**: Automatically generated from coordinates
- **Checksums**: MD5, SHA1, SHA256 uploaded automatically

### Maven2 Upload (Nexus 2.x)

- **Use case**: Upload pre-built `m2repo/` directory trees to Nexus 2.x servers
- **No coordinates needed**: The upload retains the full directory structure
- **API endpoint**: Uses `/content/repositories/<repo>/` (Nexus 2.x)
- **Checksums**: Not double-uploaded (m2repo already contains `.md5`/`.sha1` files)
- **Note**: `files_path` must be a directory, not a single file

### npm

- **Upload path**: Automatically determined from package name
- **Supports scoped packages**: `@scope/package`
- **File pattern**: Commonly `*.tgz`

### PyPI

- **Upload path**: Automatically generated from package name
- **Supports wheels and source distributions**: `*.whl`, `*.tar.gz`
- **Package name**: Extracted from filename

### Helm

- **Upload path**: Root of repository
- **File pattern**: `*.tgz`
- **Compatible with Helm repositories**

## Authentication

The action supports Nexus username/password authentication.

Store sensitive credentials as GitHub secrets:

```yaml
# In your repository secrets
NEXUS_PASSWORD: your-nexus-password

# In your workflow
nexus_password: ${{ secrets.NEXUS_PASSWORD }}
```

## Troubleshooting

### Common Issues

<!-- markdownlint-disable MD013 -->

| Error                      | Diagnostic message                                   | Solution                                                 |
| -------------------------- | ---------------------------------------------------- | -------------------------------------------------------- |
| Invalid repository format  | `Invalid repository format 'xyz'`                    | Use a supported format name (see table above)            |
| Missing Maven coordinates  | `Maven format requires groupId, artifactId, version` | Supply `coordinates: 'groupId=… artifactId=… version=…'` |
| File / directory not found | `Files path './dist' does not exist`                 | Confirm the path exists before the action runs           |

<!-- markdownlint-enable MD013 -->

### HTTP Error Codes

<!-- markdownlint-disable MD013 -->

| HTTP | Diagnostic                                 | Solution                                              |
| ---- | ------------------------------------------ | ----------------------------------------------------- |
| 400  | Repository locked for writes / bad request | Verify the repository accepts writes in Nexus admin   |
| 401  | Authentication failed: invalid credentials | Check `nexus_username` and `nexus_password`           |
| 403  | Authorisation denied: insufficient perms   | Grant write access to the upload user                 |
| 404  | Repository or upload path not found        | Check `repository_name` and `upload_path`             |
| 405  | HTTP method not allowed by this endpoint   | Confirm the Nexus API version matches `repo_format`   |
| 413  | File too large for the server to accept    | Raise the upload size limit in Nexus configuration    |
| 5xx  | Nexus internal / gateway / timeout error   | Retry later; check Nexus server health                |

<!-- markdownlint-enable MD013 -->

### Network Error Codes

<!-- markdownlint-disable MD013 -->

| curl exit | Diagnostic                             | Solution                                        |
| --------- | -------------------------------------- | ----------------------------------------------- |
| 6         | DNS resolution failed                  | Verify `nexus_server` hostname resolves         |
| 7         | Connection refused / could not connect | Check the server URL, port, and firewall rules  |
| 28        | Operation timed out                    | The 30 s connect / 300 s request limits elapsed |
| 35        | SSL/TLS handshake failed               | Verify certificates and TLS configuration       |
| 56        | Network receive error                  | Investigate network stability to the server     |

<!-- markdownlint-enable MD013 -->

### Fail-Fast Behaviour

By default (`fail_fast: 'true'`), the action stops after the first
failure when `permit_fail` is `false`. This keeps logs short and makes
failures straightforward to diagnose, even with large file sets.

To attempt **all** uploads and get a complete success/failure summary,
set `fail_fast: 'false'`:

```yaml
- uses: lfreleng-actions/nexus-publish-action@main
  with:
    fail_fast: 'false'
    permit_fail: 'false'
    # ... other inputs
```

<!-- markdownlint-disable MD013 -->

| `permit_fail` | `fail_fast` | Behaviour                                |
| ------------- | ----------- | ---------------------------------------- |
| `false`       | `true`      | Stop at first failure, exit 1            |
| `false`       | `false`     | Try all files, then exit 1 if any failed |
| `true`        | (ignored)   | Try all files, exit 0 regardless         |

<!-- markdownlint-enable MD013 -->

### Debug Information

The action provides comprehensive logging including:

- Configuration summary (server, repository, format, fail-fast mode)
- File discovery results
- Upload URLs
- Per-file HTTP status codes and Nexus error messages
- Checksum upload status with per-algorithm reporting
- Human-readable diagnostics for network and HTTP errors
- Publication summary with success, failure, and skipped counts

## Implementation Details

1. Validates inputs and repository format
2. Discovers files based on path and pattern
3. Determines format-specific upload URLs and methods
4. Uploads files with Nexus-aware error handling:
   - Captures full HTTP response bodies for diagnostics
   - Parses Nexus 2.x XML and Nexus 3.x JSON error messages
   - Translates HTTP status codes into actionable descriptions
   - Reports network errors with human-readable curl diagnostics
   - Enforces connection timeouts (30s) and request timeouts (300s)
5. Calculates and uploads checksums when enabled, reporting per-algorithm
   success or failure
6. Supports fail-fast termination or full-run summary mode

The action supports both simple raw uploads and complex format-specific
uploads with proper metadata handling.
