#!/bin/bash

set -euo pipefail

IMAGE=""
DOCKERFILE=""
OUTPUT=""
SIZE_MB=512

usage() {
    cat << EOF
Usage: $0 -i IMAGE_TAG [OPTIONS]
       $0 -f DOCKERFILE [OPTIONS]

Build a single rootfs image for Firecracker from a Docker image or Dockerfile.

Required (choose one):
  -i IMAGE_TAG     Docker image tag (e.g., ubuntu:22.04, alpine:latest)
  -f DOCKERFILE    Path to Dockerfile to build and extract

Optional:
  -o OUTPUT        Output filename (default: <image_name>.ext4)
  -s SIZE_MB       Extra size in MB to add to filesystem (default: 512)
  -h               Show this help

Examples:
  $0 -i ubuntu:22.04
  $0 -i alpine:latest -o my-alpine.ext4
  $0 -f ./Dockerfile -o custom-image.ext4
  $0 -f ./Dockerfile -s 1024
EOF
}

cleanup() {
    if [[ -n "${MOUNT_DIR:-}" && -d "$MOUNT_DIR" ]]; then
        if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
            umount -l "$MOUNT_DIR" || true
        fi
        rmdir "$MOUNT_DIR" || true
    fi
    
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR" || true
    fi
    
    if [[ -n "${CONTAINER_ID:-}" ]]; then
        docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

while getopts "i:f:o:s:h" opt; do
    case $opt in
        i) IMAGE="$OPTARG" ;;
        f) DOCKERFILE="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        s) SIZE_MB="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

if [[ -z "$IMAGE" && -z "$DOCKERFILE" ]]; then
    echo "Error: Either image tag (-i) or dockerfile (-f) is required"
    usage
    exit 1
fi

if [[ -n "$IMAGE" && -n "$DOCKERFILE" ]]; then
    echo "Error: Cannot specify both image and dockerfile"
    usage
    exit 1
fi

# Check dependencies
for cmd in docker mkfs.ext4 ssh-keygen; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Missing required command: $cmd"
        exit 1
    fi
done

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo "Error: Docker is not running or not accessible"
    exit 1
fi

# Handle dockerfile case
if [[ -n "$DOCKERFILE" ]]; then
    if [[ ! -f "$DOCKERFILE" ]]; then
        echo "Error: Dockerfile not found: $DOCKERFILE"
        exit 1
    fi
    
    TEMP_TAG="firecracker-rootfs-temp:$(date +%s)"
    echo "Building Docker image from $DOCKERFILE..."
    docker build -f "$DOCKERFILE" -t "$TEMP_TAG" "$(dirname "$DOCKERFILE")"
    IMAGE="$TEMP_TAG"
    CLEANUP_IMAGE=true
fi

# Set default output name
if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$(basename "${IMAGE/:/-}").ext4"
fi

echo "Building rootfs for: $IMAGE"
echo "Output file: $OUTPUT"

# Try to pull the image if it doesn't exist locally (unless it's our temp image)
if [[ -z "${CLEANUP_IMAGE:-}" ]]; then
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "Image not found locally, pulling: $IMAGE"
        docker pull "$IMAGE"
    fi
fi

# Create temporary directories
TEMP_DIR=$(mktemp -d)
MOUNT_DIR="$TEMP_DIR/rootfs"
mkdir -p "$MOUNT_DIR"

# Create container to extract filesystem
echo "Creating container from image..."
CONTAINER_ID=$(docker create "$IMAGE")

# Export container filesystem
echo "Exporting container filesystem..."
docker export "$CONTAINER_ID" | tar -xf - -C "$MOUNT_DIR"

# Calculate required size
echo "Calculating filesystem size..."
MOUNT_SIZE=$(du -sb "$MOUNT_DIR" | cut -f1)
TOTAL_SIZE=$(( MOUNT_SIZE + SIZE_MB * 1024 * 1024 ))

echo "Filesystem content size: $(( MOUNT_SIZE / 1024 / 1024 )) MB"
echo "Total image size: $(( TOTAL_SIZE / 1024 / 1024 )) MB"

# Generate SSH key for access
KEY_FILE="$TEMP_DIR/id_rsa"
if [[ ! -f "id_rsa" ]]; then
    echo "Generating SSH key..."
    ssh-keygen -f "$KEY_FILE" -N "" -q
else
    echo "Using existing SSH key..."
    cp id_rsa "$KEY_FILE"
    cp id_rsa.pub "$KEY_FILE.pub"
fi

# Set up SSH access
echo "Setting up SSH access..."
install -d -m 0700 "$MOUNT_DIR/root/.ssh/"
cp "$KEY_FILE.pub" "$MOUNT_DIR/root/.ssh/authorized_keys"
chmod 600 "$MOUNT_DIR/root/.ssh/authorized_keys"

# Copy SSH key to current directory for user access
cp "$KEY_FILE" "./$(basename "$OUTPUT" .ext4).id_rsa"
chmod 600 "./$(basename "$OUTPUT" .ext4).id_rsa"

# Create the ext4 filesystem
echo "Creating ext4 filesystem: $OUTPUT"
truncate -s "$TOTAL_SIZE" "$OUTPUT"
mkfs.ext4 -F "$OUTPUT" -d "$MOUNT_DIR"

# Mount and configure the image
LOOP_MOUNT="$TEMP_DIR/loop_mount"
mkdir -p "$LOOP_MOUNT"
mount "$OUTPUT" "$LOOP_MOUNT"

# Install packages and configure system based on distro
echo "Configuring system inside container..."
systemd-nspawn --timezone=off --pipe -i "$OUTPUT" /bin/sh <<'EOF' || true
set -x

# Detect distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    # Fallback detection
    if command -v apt >/dev/null 2>&1; then
        ID="ubuntu"
    elif command -v apk >/dev/null 2>&1; then
        ID="alpine"
    elif command -v dnf >/dev/null 2>&1; then
        ID="amzn"
    elif command -v yum >/dev/null 2>&1; then
        ID="centos"
    fi
fi

case "$ID" in
ubuntu|debian)
    export DEBIAN_FRONTEND=noninteractive
    apt update || true
    apt install -y openssh-server iproute2 udev || true
    systemctl enable ssh || true
    ;;
alpine)
    apk add --no-cache openssh openrc || true
    rc-update add sshd || true
    echo "ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100" >> /etc/inittab || true
    ;;
amzn|centos|rhel|fedora)
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y openssh-server iproute passwd systemd-udev || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y openssh-server iproute passwd || true
    fi
    systemctl enable sshd || true
    ;;
*)
    echo "Unknown distribution: $ID, skipping package installation"
    ;;
esac

# Enable root login without password
passwd -d root 2>/dev/null || true

# Enable serial console
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true

EOF

# Unmount
umount "$LOOP_MOUNT"

# Clean up temp image if we built it
if [[ -n "${CLEANUP_IMAGE:-}" ]]; then
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
fi

echo ""
echo "✓ Rootfs image created: $OUTPUT"
echo "✓ SSH private key: $(basename "$OUTPUT" .ext4).id_rsa"
echo ""
echo "Usage with Firecracker:"
echo "  firecracker --kernel-image-path vmlinux \\"
echo "              --rootfs-path $OUTPUT \\"
echo "              --config-file config.json"
echo ""
echo "SSH access (once running):"
echo "  ssh -i $(basename "$OUTPUT" .ext4).id_rsa root@<guest-ip>"
