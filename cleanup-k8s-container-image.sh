#!/usr/bin/env bash
# cleanup-k8s-container-image.sh
# Kubernetes Container Image Cleanup Utility
# Scans pods for a specific container (or all), finds its image, and removes it locally.

set -euo pipefail

# Load .env File if present (safely parses key=value pairs)
if [[ -f .env ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignore comments and empty lines
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        
        if [[ "$line" == *=* ]]; then
            key="${line%%=*}"
            value="${line#*=}"
            # Strip outer single/double quotes if present
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            export "$key=$value"
        fi
    done < .env
fi

# Fallback environment overrides
ARTIFACTORY_REGISTRY="${ARTIFACTORY_REGISTRY:-docker-snapshot.abc.def.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-abc/alpfr/analytics/datarobot/dr_11_1_8}"

NAMESPACE=""
CONTAINER_NAME="all"
VENDOR=""
DRY_RUN=false
FILTER_PATTERN="dr_11_1_8"

usage() {
    cat <<EOF
Usage:
    $0 -n <namespace> [options]

Options:
    -n, --namespace NS    Kubernetes namespace to scan (Required)
    -c, --container NAME  Name of the specific container to target (default: "all")
    -f, --filter PATTERN  Filter image by matching pattern (default: "dr_11_1_8")
                          Pass empty string "" to disable filtering
    -v, --vendor VENDOR   Container runtime vendor: docker, podman, or crictl (default: auto-detect)
    -d, --dry-run         Show what would be done without removing images
    -h, --help            Show this help message and exit

Environment Variables:
    ARTIFACTORY_REGISTRY   Target Artifactory registry host (default: docker-snapshot.abc.def.com)
    ARTIFACTORY_REPO       Target Artifactory docker repository (default: abc/alpfr/analytics/datarobot/dr_11_1_8)

Examples:
    $0 -n production -c web
    $0 -n production -c all -f "dr_11_1_9"
    $0 -n production -c web -v podman -d
EOF
    exit 1
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -c|--container)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -v|--vendor)
            VENDOR="$2"
            shift 2
            ;;
        -f|--filter)
            FILTER_PATTERN="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "$NAMESPACE" ]]; then
    echo "ERROR: Namespace (-n / --namespace) is a required argument." >&2
    usage
fi

# Prerequisite Verification
CONTAINER_CLI=""

check_prereqs() {
    local missing=0
    
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "ERROR: 'kubectl' command line tool is not installed or not in PATH." >&2
        missing=1
    fi
    
    if [[ -n "${VENDOR}" ]]; then
        if [[ "${VENDOR}" != "docker" ]] && [[ "${VENDOR}" != "podman" ]] && [[ "${VENDOR}" != "crictl" ]]; then
            echo "ERROR: Invalid vendor '${VENDOR}'. Must be 'docker', 'podman', or 'crictl'." >&2
            missing=1
        elif [[ "${DRY_RUN}" == "false" ]] && ! command -v "${VENDOR}" >/dev/null 2>&1; then
            echo "ERROR: Specified container runtime '${VENDOR}' is not installed or not in PATH." >&2
            missing=1
        else
            CONTAINER_CLI="${VENDOR}"
        fi
    else
        # Auto-detect container runtime
        if command -v docker >/dev/null 2>&1; then
            CONTAINER_CLI="docker"
        elif command -v podman >/dev/null 2>&1; then
            CONTAINER_CLI="podman"
        elif command -v crictl >/dev/null 2>&1; then
            CONTAINER_CLI="crictl"
        else
            if [[ "${DRY_RUN}" == "true" ]]; then
                echo "WARNING: No container runtime found in PATH. Defaulting to 'docker' simulation." >&2
                CONTAINER_CLI="docker"
            else
                echo "ERROR: No container runtime tool ('docker', 'podman', or 'crictl') found in PATH." >&2
                missing=1
            fi
        fi
    fi
    
    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

validate_namespace() {
    local ns="$1"
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        if $DRY_RUN; then
            echo "WARNING: Namespace '${ns}' does not exist or is inaccessible." >&2
            echo "         (Proceeding anyway because --dry-run is active)" >&2
        else
            echo "ERROR: Namespace '${ns}' does not exist or is inaccessible." >&2
            exit 1
        fi
    fi
}

# Image Existence Helper
image_exists() {
    local img="$1"
    if [[ "${CONTAINER_CLI}" == "crictl" ]]; then
        sudo crictl inspecti "$img" >/dev/null 2>&1
    else
        "$CONTAINER_CLI" image inspect "$img" >/dev/null 2>&1
    fi
}

# Remove Image Helper
remove_image() {
    local img="$1"
    if [[ "${CONTAINER_CLI}" == "crictl" ]]; then
        sudo crictl rmi "$img" >/dev/null 2>&1
    else
        "$CONTAINER_CLI" rmi "$img" >/dev/null 2>&1
    fi
}

# Prune Images Helper
prune_images() {
    if [[ "${CONTAINER_CLI}" == "crictl" ]]; then
        sudo crictl rmi --prune >/dev/null 2>&1 || true
    else
        "$CONTAINER_CLI" image prune -f >/dev/null 2>&1 || true
    fi
}

# Target Tag Parsing (Extract Base Image Name)
get_target_image() {
    local source_image="$1"
    
    # 1. Extract the base image name (everything after the last slash)
    local base_image="${source_image##*/}"
    
    # 2. Handle image digests: docker tags cannot contain '@' or ':sha256:'
    local normalized_ref="$base_image"
    if [[ "$normalized_ref" == *@sha256:* ]]; then
        local base_part="${normalized_ref%%@*}"
        if [[ "$base_part" == *:* ]]; then
            normalized_ref=$(echo "$normalized_ref" | sed 's/@sha256:/-sha256-/')
        else
            normalized_ref=$(echo "$normalized_ref" | sed 's/@sha256:/:sha256-/')
        fi
    fi
    
    echo "${ARTIFACTORY_REGISTRY}/${ARTIFACTORY_REPO}/${normalized_ref}"
}

# Main Execution
check_prereqs
validate_namespace "$NAMESPACE"

echo "Scanning namespace '${NAMESPACE}' for containers named '${CONTAINER_NAME}' using ${CONTAINER_CLI}..."

# Use a temporary file and ensure cleanup
TMP_IMAGES=$(mktemp -t k8s-images-cleanup.XXXXXXXX)
trap 'rm -f "$TMP_IMAGES"' EXIT

# Extract image(s) for the specified container name
if [[ -n "${FILTER_PATTERN:-}" ]]; then
    echo "Filtering image by matching pattern: '${FILTER_PATTERN}'"
    kubectl get pods -n "$NAMESPACE" \
        -o jsonpath="{range .items[*]}{range .spec.initContainers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.containers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.ephemeralContainers[*]}{.name}{' '}{.image}{'\n'}{end}{end}" \
        | grep "${FILTER_PATTERN}" \
        | awk -v target="$CONTAINER_NAME" 'target == "all" || $1 == target {print $2}' \
        | sort -u > "$TMP_IMAGES" || true
else
    echo "Collecting container image without pattern filtering"
    kubectl get pods -n "$NAMESPACE" \
        -o jsonpath="{range .items[*]}{range .spec.initContainers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.containers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.ephemeralContainers[*]}{.name}{' '}{.image}{'\n'}{end}{end}" \
        | awk -v target="$CONTAINER_NAME" 'target == "all" || $1 == target {print $2}' \
        | sort -u > "$TMP_IMAGES"
fi

IMAGE_COUNT=$(grep -cv '^$' "$TMP_IMAGES" || true)

if [[ ${IMAGE_COUNT} -eq 0 ]]; then
    if [[ -n "${FILTER_PATTERN:-}" ]]; then
        echo "ERROR: No container named '${CONTAINER_NAME}' found in namespace '${NAMESPACE}' matching filter pattern '${FILTER_PATTERN}'." >&2
    else
        echo "ERROR: No container named '${CONTAINER_NAME}' found in namespace '${NAMESPACE}'." >&2
    fi
    exit 1
fi

echo
echo "Found ${IMAGE_COUNT} unique image(s) for container '${CONTAINER_NAME}':"
cat "$TMP_IMAGES"
echo

# Process Image Purge
SUCCESS=0
FAILED=0

while read -r IMAGE; do
    [[ -z "$IMAGE" ]] && continue
    
    TARGET_IMAGE=$(get_target_image "$IMAGE")
    
    echo "========================================================"
    echo "Source : ${IMAGE}"
    echo "Target : ${TARGET_IMAGE}"
    
    if $DRY_RUN; then
        if image_exists "$IMAGE"; then
            echo "[DRY-RUN] Would remove local image: ${IMAGE}"
        else
            echo "[DRY-RUN] (Local image '${IMAGE}' is not present on this host)"
        fi
        if image_exists "$TARGET_IMAGE"; then
            echo "[DRY-RUN] Would remove local tag  : ${TARGET_IMAGE}"
        else
            echo "[DRY-RUN] (Local tag '${TARGET_IMAGE}' is not present on this host)"
        fi
        SUCCESS=$((SUCCESS+1))
        continue
    fi
    
    any_action=false
    image_removed=false
    tag_removed=false
    
    if image_exists "$IMAGE"; then
        any_action=true
        echo "Removing local image: ${IMAGE}"
        if remove_image "$IMAGE"; then
            echo "✔ Removed source tag successfully"
            image_removed=true
        else
            echo "✖ Failed to remove source tag ${IMAGE}"
        fi
    fi
    
    if image_exists "$TARGET_IMAGE"; then
        any_action=true
        echo "Removing local tag  : ${TARGET_IMAGE}"
        if remove_image "$TARGET_IMAGE"; then
            echo "✔ Removed target tag successfully"
            tag_removed=true
        else
            echo "✖ Failed to remove target tag ${TARGET_IMAGE}"
        fi
    fi
    
    if ! $any_action; then
        echo "Info: Neither image nor target tag are present on this host."
        SUCCESS=$((SUCCESS+1))
    elif $image_removed || $tag_removed; then
        SUCCESS=$((SUCCESS+1))
    else
        echo "ERROR: Failed to remove either tag (they may be in use by a container)"
        FAILED=$((FAILED+1))
    fi
done < "$TMP_IMAGES"

# Sweep intermediate dangling layers
if ! $DRY_RUN; then
    echo
    echo "Sweeping intermediate dangling layers to reclaim additional space..."
    prune_images
fi

# Summary
echo
echo "==================== Summary ===================="
echo "Namespace      : ${NAMESPACE}"
echo "Container Name : ${CONTAINER_NAME}"
echo "Dry Run        : ${DRY_RUN}"
echo "Images Found   : ${IMAGE_COUNT}"
echo "Removed        : ${SUCCESS}"
echo "Failed         : ${FAILED}"
echo "================================================="

if [[ ${FAILED} -gt 0 ]]; then
    exit 1
fi
