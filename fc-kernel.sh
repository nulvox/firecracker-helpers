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

# Fetch kernel command line parameters from CI configuration
fetch_kernel_cmdline() {
    echo "Fetching kernel command line parameters from CI configuration..."
    
    # Common paths where CI config files might contain kernel cmdline
    local config_paths=(
        "tests/framework/utils.py"
        "tests/integration_tests/functional/test_api.py"
        "tests/integration_tests/performance/test_network_performance.py"
        "tests/integration_tests/build/test_build_and_run.py"
        "tools/devctr"
        ".buildkite/pipeline.yml"
        ".github/workflows"
    )
    
    local cmdline_file="$OUTPUT_DIR/kernel_cmdline_params.txt"
    local config_file="$OUTPUT_DIR/firecracker_config_template.json"
    
    echo "Searching for kernel command line parameters in CI files..."
    
    # Try to fetch common configuration files that contain kernel cmdline
    local base_url="https://raw.githubusercontent.com/firecracker-microvm/firecracker/$COMMIT_HASH"
    
    # Check utils.py for default kernel cmdline
    local utils_url="$base_url/tests/framework/utils.py"
    if curl -s -f "$utils_url" -o /tmp/utils.py 2>/dev/null; then
        echo "Analyzing tests/framework/utils.py for kernel parameters..."
        
        # Extract kernel command line parameters
        if grep -n "kernel.*cmdline\|boot.*args\|console=ttyS0" /tmp/utils.py > /tmp/kernel_params.txt 2>/dev/null; then
            {
                echo "# Kernel command line parameters found in tests/framework/utils.py"
                echo "# Commit: $COMMIT_HASH"
                echo "# Source: $utils_url"
                echo ""
                
                # Extract common parameters
                grep -o "console=[^[:space:]\"']*" /tmp/utils.py | head -1 || echo "console=ttyS0"
                grep -o "reboot=[^[:space:]\"']*" /tmp/utils.py | head -1 || true
                grep -o "panic=[^[:space:]\"']*" /tmp/utils.py | head -1 || echo "panic=1"
                grep -o "pci=[^[:space:]\"']*" /tmp/utils.py | head -1 || true
                grep -o "i8042[^[:space:]\"']*" /tmp/utils.py | head -1 || true
                
                echo ""
                echo "# Full matches from source:"
                cat /tmp/kernel_params.txt | sed 's/^/# /'
                
            } > "$cmdline_file"
            
            echo "  ✓ Kernel cmdline saved to: $cmdline_file"
        fi
        
        rm -f /tmp/utils.py /tmp/kernel_params.txt
    fi
    
    # Try to get a sample firecracker configuration
    local config_urls=(
        "$base_url/tests/integration_tests/functional/test_api.py"
        "$base_url/tests/framework/microvm.py"
        "$base_url/resources/tests/test_config.json"
    )
    
    for config_url in "${config_urls[@]}"; do
        if curl -s -f "$config_url" -o /tmp/config_source 2>/dev/null; then
            echo "Analyzing $(basename "$config_url") for Firecracker configuration..."
            
            # Look for JSON configuration patterns
            if grep -A 50 -B 5 '"boot-source"\|"kernel_image_path"\|"kernel_args"' /tmp/config_source > /tmp/config_extract.txt 2>/dev/null; then
                {
                    echo "{"
                    echo "  \"boot-source\": {"
                    echo "    \"kernel_image_path\": \"./vmlinux\","
                    echo "    \"boot_args\": \"$(cat "$cmdline_file" 2>/dev/null | grep -v '^#' | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//' || echo 'console=ttyS0 reboot=k panic=1 pci=off')\","
                    echo "    \"initrd_path\": null"
                    echo "  },"
                    echo "  \"drives\": ["
                    echo "    {"
                    echo "      \"drive_id\": \"rootfs\","
                    echo "      \"path_on_host\": \"./rootfs.ext4\","
                    echo "      \"is_root_device\": true,"
                    echo "      \"is_read_only\": false"
                    echo "    }"
                    echo "  ],"
                    echo "  \"machine-config\": {"
                    echo "    \"vcpu_count\": 1,"
                    echo "    \"mem_size_mib\": 128"
                    echo "  }"
                    echo "}"
                } > "$config_file"
                
                echo "  ✓ Sample Firecracker config saved to: $config_file"
                break
            fi
            
            rm -f /tmp/config_source /tmp/config_extract.txt
        fi
    done
    
    # If we couldn't find specific parameters, provide sensible defaults
    if [[ ! -f "$cmdline_file" ]]; then
        {
            echo "# Default kernel command line parameters for Firecracker"
            echo "# Commit: $COMMIT_HASH (defaults used - no specific params found)"
            echo ""
            echo "console=ttyS0"
            echo "reboot=k"
            echo "panic=1"
            echo "pci=off"
        } > "$cmdline_file"
        echo "  ✓ Default kernel cmdline saved to: $cmdline_file"
    fi
    
    if [[ ! -f "$config_file" ]]; then
        {
            echo "{"
            echo "  \"boot-source\": {"
            echo "    \"kernel_image_path\": \"./vmlinux\","
            echo "    \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off\","
            echo "    \"initrd_path\": null"
            echo "  },"
            echo "  \"drives\": ["
            echo "    {"
            echo "      \"drive_id\": \"rootfs\","
            echo "      \"path_on_host\": \"./rootfs.ext4\","
            echo "      \"is_root_device\": true,"
            echo "      \"is_read_only\": false"
            echo "    }"
            echo "  ],"
            echo "  \"machine-config\": {"
            echo "    \"vcpu_count\": 1,"
            echo "    \"mem_size_mib\": 128"
            echo "  }"
            echo "}"
        } > "$config_file"
        echo "  ✓ Default Firecracker config saved to: $config_file"
    fi
}

# Fetch kernel command line parameters
fetch_kernel_cmdline

echo ""
echo "Download complete!"
echo "Files saved to: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"

# Show usage information
if [[ -f "$OUTPUT_DIR/kernel_cmdline_params.txt" ]]; then
    echo ""
    echo "Kernel command line parameters:"
    echo "==============================="
    cat "$OUTPUT_DIR/kernel_cmdline_params.txt" | grep -v '^#'
fi

echo ""
echo "Usage:"
echo "  firecracker --config-file $OUTPUT_DIR/firecracker_config_template.json"