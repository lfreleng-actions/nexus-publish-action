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
- **Error Handling**: Continues processing other files if individual uploads fail

## Supported Repository Formats

<!-- markdownlint-enable MD013 -->

| Format      | Description             | Example Files                |
| ----------- | ----------------------- | ---------------------------- |
| `raw`       | Generic binary files    | `*.zip`, `*.tar.gz`, `*.bin` |
| `maven2`    | Java artifacts          | `*.jar`, `*.war`, `*.pom`    |
| `npm`       | Node.js packages        | `*.tgz`                      |
| `docker`    | Container images        | N/A (registry API)           |
| `helm`      | Kubernetes charts       | `*.tgz`                      |
| `pypi`      | Python packages         | `*.whl`, `*.tar.gz`          |
| `nuget`     | .NET packages           | `*.nupkg`                    |
| `rubygems`  | Ruby gems               | `*.gem`                      |
| `apt`       | Debian packages         | `*.deb`                      |
| `yum`/`rpm` | Red Hat packages        | `*.rpm`                      |
| `composer`  | PHP packages            | `*.zip`                      |
| `conan`     | C/C++ packages          | `*.tgz`                      |
| `conda`     | Multi-language packages | `*.tar.bz2`                  |
| `r`         | R packages              | `*.tar.gz`                   |
| `go`        | Go modules              | `*.zip`                      |
| `p2`        | Eclipse plugins         | `*.jar`                      |
| `gitlfs`    | Git LFS objects         | Any large files              |
| `cocoapods` | iOS/macOS packages      | `*.tar.gz`                   |
| `bower`     | Frontend packages       | `*.tar.gz`                   |

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

## Inputs

### Required

<!-- markdownlint-disable MD013 -->

| Name                | Description |
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
| `permit_fail`       | Do not exit/error when some content fails to upload    | `true`           |

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

1. **Invalid repository format**

   ```text
   Error: Invalid repository format 'xyz'. Supported formats: raw maven2
   npm docker helm pypi nuget...
   ```

   **Solution**: Use one of the supported format names

2. **Missing coordinates for Maven**

   ```text
   Error: Maven format requires groupId, artifactId, and version in coordinates
   ```

   **Solution**: Provide coordinates in the format:
   `groupId=com.example artifactId=app version=1.0.0`

3. **File not found**

   ```text
   Error: Files path './dist' does not exist
   ```

   **Solution**: Ensure the file or directory exists before running the action

4. **Authentication failure**

   ```text
   ❌ Failed to upload: filename.jar
   ```

   **Solution**: Verify nexus_username and nexus_password are correct

### Debug Information

The action provides comprehensive logging including:

- Configuration summary
- File discovery results
- Upload URLs
- Checksum information
- Success/failure status for each file

## Implementation Details

1. Validates inputs and repository format
2. Discovers files based on path and pattern
3. Determines format-specific upload URLs and methods
4. Calculates and uploads checksums when enabled
5. Provides detailed progress reporting
6. Handles errors robustly and continues with remaining files

The action supports both simple raw uploads and complex format-specific
uploads with proper metadata handling.
