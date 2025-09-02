#!/bin/bash

set -euo pipefail

RELEASE_VERSION=""
COMMIT_HASH=""
ARCH="x86_64"
KERNEL_VERSION="5.10"
VARIANT="acpi"
OUTPUT_DIR="./kernels"

usage() {
    cat << EOF
Usage: $0 -r RELEASE_VERSION [OPTIONS]
       $0 -c COMMIT_HASH [OPTIONS]

Download Firecracker CI kernel images for a specific release or commit.

Required (choose one):
  -r RELEASE_VER    Firecracker release version (e.g., v1.7.0, v1.8.0)
  -c COMMIT_HASH    Git commit hash from firecracker repo

Optional:
  -a ARCH          Architecture (default: x86_64, options: x86_64, aarch64)
  -k KERNEL_VER    Kernel version (default: 5.10)
  -v VARIANT       Kernel variant (default: acpi, options: acpi, microvm)
  -o OUTPUT_DIR    Output directory (default: ./kernels)
  -h               Show this help

Examples:
  $0 -r v1.7.0
  $0 -r v1.8.0 -a aarch64 -k 6.1 -v microvm
  $0 -c abc123def456
EOF
}

while getopts "r:c:a:k:v:o:h" opt; do
    case $opt in
        r) RELEASE_VERSION="$OPTARG" ;;
        c) COMMIT_HASH="$OPTARG" ;;
        a) ARCH="$OPTARG" ;;
        k) KERNEL_VERSION="$OPTARG" ;;
        v) VARIANT="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

if [[ -z "$RELEASE_VERSION" && -z "$COMMIT_HASH" ]]; then
    echo "Error: Either release version (-r) or commit hash (-c) is required"
    usage
    exit 1
fi

if [[ -n "$RELEASE_VERSION" && -n "$COMMIT_HASH" ]]; then
    echo "Error: Cannot specify both release version and commit hash"
    usage
    exit 1
fi

# Function to get commit hash from release version
get_commit_from_release() {
    local release="$1"
    echo "Looking up commit hash for release: $release"
    
    # GitHub API URL for the release
    local api_url="https://api.github.com/repos/firecracker-microvm/firecracker/releases/tags/$release"
    
    # Get release info from GitHub API
    local response=$(curl -s "$api_url")
    
    if echo "$response" | grep -q '"message": "Not Found"'; then
        echo "Error: Release $release not found"
        echo "Available releases can be found at: https://github.com/firecracker-microvm/firecracker/releases"
        exit 1
    fi
    
    # Extract target_commitish from the response
    local commit=$(echo "$response" | grep -oP '"target_commitish":\s*"\K[^"]+')
    
    if [[ -z "$commit" ]]; then
        echo "Error: Could not extract commit hash from release $release"
        exit 1
    fi
    
    echo "Found commit hash: $commit"
    echo "$commit"
}

# Get commit hash if release version was provided
if [[ -n "$RELEASE_VERSION" ]]; then
    COMMIT_HASH=$(get_commit_from_release "$RELEASE_VERSION")
fi

# Validate architecture
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
    echo "Error: Architecture must be x86_64 or aarch64"
    exit 1
fi

echo "Searching for kernels built from commit: $COMMIT_HASH"
echo "Architecture: $ARCH"
echo "Kernel version: $KERNEL_VERSION"
echo "Variant: $VARIANT"

S3_BASE="https://s3.amazonaws.com/spec.ccfc.min"
S3_LIST_BASE="http://spec.ccfc.min.s3.amazonaws.com"

# Function to find kernel files for a specific pattern
find_kernel_files() {
    local prefix="$1"
    echo "Checking S3 path: $prefix"
    
    # List objects with the given prefix
    local list_url="${S3_LIST_BASE}/?prefix=${prefix}&list-type=2"
    local response=$(curl -s "$list_url")
    
    if [[ -z "$response" ]]; then
        echo "No response from S3 listing"
        return 1
    fi
    
    # Extract kernel files matching our pattern
    local kernel_files=$(echo "$response" | grep -oP "(?<=<Key>)${prefix}vmlinux-${KERNEL_VERSION}\.[0-9]+(?=</Key>)" || true)
    local config_files=$(echo "$response" | grep -oP "(?<=<Key>)${prefix}vmlinux-${KERNEL_VERSION}\.[0-9]+\.config(?=</Key>)" || true)
    
    if [[ -n "$kernel_files" || -n "$config_files" ]]; then
        echo "Found files:"
        echo "$kernel_files" | while read -r file; do
            [[ -n "$file" ]] && echo "  $file"
        done
        echo "$config_files" | while read -r file; do
            [[ -n "$file" ]] && echo "  $file"
        done
        
        # Return both types concatenated
        echo -e "${kernel_files}\n${config_files}"
        return 0
    fi
    
    return 1
}

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Try different path patterns where kernels might be stored
SEARCH_PATHS=(
    "firecracker-ci/${VARIANT}/${ARCH}/"
    "firecracker-ci/${ARCH}/"
    "firecracker-ci/v1.10/${ARCH}/"
    "firecracker-ci/main/${ARCH}/"
    "firecracker-ci/commits/${COMMIT_HASH}/${ARCH}/"
)

found_files=""
for path in "${SEARCH_PATHS[@]}"; do
    echo "Searching in: $path"
    if files=$(find_kernel_files "$path"); then
        found_files="$files"
        found_path="$path"
        break
    fi
done

if [[ -z "$found_files" ]]; then
    echo "No kernel files found for commit $COMMIT_HASH"
    echo "Tried paths:"
    printf '  %s\n' "${SEARCH_PATHS[@]}"
    echo ""
    echo "You may need to:"
    echo "1. Check if the commit hash is correct"
    echo "2. Verify the commit has CI builds completed"
    echo "3. Try different architecture/kernel version combinations"
    exit 1
fi

echo ""
echo "Found files in path: $found_path"
echo "Downloading to: $OUTPUT_DIR"

# Download found files
download_count=0
echo "$found_files" | while read -r file; do
    if [[ -n "$file" ]]; then
        filename=$(basename "$file")
        url="${S3_BASE}/${file}"
        output_path="${OUTPUT_DIR}/${filename}"
        
        echo "Downloading: $filename"
        if curl -f -o "$output_path" "$url"; then
            echo "  ✓ Downloaded: $output_path"
            ((download_count++))
        else
            echo "  ✗ Failed to download: $url"
        fi
    fi
done

echo ""
echo "Download complete!"
echo "Files saved to: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
