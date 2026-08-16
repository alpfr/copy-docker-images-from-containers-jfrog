#!/bin/bash

set -euo pipefail

################################################################################
# Kubernetes Container Image Cleanup Utility
# Scans pods for a specific container, finds its image, and removes it locally
################################################################################

ARTIFACTORY_REGISTRY="${ARTIFACTORY_REGISTRY:-docker-snapshot.abc.def.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-abc/alpfr/analytics/datarobot/dr_11_1_8}"

DRY_RUN=false
FILTER_PATTERN="dr_11_1_8"

usage() {
    cat <<EOF
Usage:
    $0 <namespace> <container_name> [options]

Arguments:
    namespace       Kubernetes namespace to scan
    container_name  Name of the specific container to target for image cleanup

Options:
    -f, --filter PATTERN  Filter image by matching pattern (default: dr_11_1_8)
                          Pass empty string "" to disable filtering
    -d, --dry-run         Show what would be done without removing images
    -h, --help            Show this help message and exit

Environment Variables:
    ARTIFACTORY_REGISTRY   Target Artifactory registry host (default: docker-snapshot.abc.def.com)
    ARTIFACTORY_REPO       Target Artifactory docker repository (default: abc/alpfr/analytics/datarobot/dr_11_1_8)

Examples:
    $0 production web
    $0 production web -f "dr_11_1_9"
    $0 production web -d
EOF
    exit 1
}

# Argument Parsing
NAMESPACE=""
CONTAINER_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=true
            ;;
        -f|--filter)
            if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                echo "ERROR: --filter requires a pattern argument." >&2
                usage
            fi
            FILTER_PATTERN="$2"
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
        *)
            if [[ -z "$NAMESPACE" ]]; then
                NAMESPACE="$1"
            elif [[ -z "$CONTAINER_NAME" ]]; then
                CONTAINER_NAME="$1"
            else
                echo "ERROR: Extra argument specified: '$1'" >&2
                usage
            fi
            ;;
    esac
    shift
done

if [[ -z "$NAMESPACE" ]] || [[ -z "$CONTAINER_NAME" ]]; then
    echo "ERROR: Both namespace and container name are required arguments." >&2
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
    
    # Detect docker or podman
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CLI="docker"
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CLI="podman"
    else
        echo "ERROR: Neither 'docker' nor 'podman' command line tool was found in PATH." >&2
        missing=1
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

# Target Tag Parsing (Extract Base Image Name)
################################################################################
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
        | awk -v target="$CONTAINER_NAME" '$1 == target {print $2}' \
        | sort -u > "$TMP_IMAGES" || true
else
    echo "Collecting container image without pattern filtering"
    kubectl get pods -n "$NAMESPACE" \
        -o jsonpath="{range .items[*]}{range .spec.initContainers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.containers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.ephemeralContainers[*]}{.name}{' '}{.image}{'\n'}{end}{end}" \
        | awk -v target="$CONTAINER_NAME" '$1 == target {print $2}' \
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

################################################################################
# Process Image Purge
################################################################################
SUCCESS=0
FAILED=0

while read -r IMAGE; do
    [[ -z "$IMAGE" ]] && continue
    
    TARGET_IMAGE=$(get_target_image "$IMAGE")
    
    echo "========================================================"
    echo "Source : ${IMAGE}"
    echo "Target : ${TARGET_IMAGE}"
    
    if $DRY_RUN; then
        echo "[DRY-RUN] Would remove local image: ${IMAGE}"
        echo "[DRY-RUN] Would remove local tag  : ${TARGET_IMAGE}"
        SUCCESS=$((SUCCESS+1))
        continue
    fi
    
    echo "Removing local images: ${IMAGE} and ${TARGET_IMAGE}"
    local image_removed=false
    local tag_removed=false
    
    if "$CONTAINER_CLI" rmi "$IMAGE" >/dev/null 2>&1; then
        image_removed=true
    fi
    
    if "$CONTAINER_CLI" rmi "$TARGET_IMAGE" >/dev/null 2>&1; then
        tag_removed=true
    fi
    
    if $image_removed || $tag_removed; then
        echo "✔ Successfully removed local images"
        SUCCESS=$((SUCCESS+1))
    else
        echo "✖ Failed to remove images (may be in use by a container)"
        FAILED=$((FAILED+1))
    fi
done < "$TMP_IMAGES"

# Sweep intermediate dangling layers
if ! $DRY_RUN; then
    echo
    echo "Sweeping intermediate dangling layers to reclaim additional space..."
    "$CONTAINER_CLI" image prune -f >/dev/null 2>&1 || true
fi

################################################################################
# Summary
################################################################################
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
