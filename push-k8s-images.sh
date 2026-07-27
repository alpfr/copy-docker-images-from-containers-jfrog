#!/bin/bash

set -euo pipefail

################################################################################
# Configuration
################################################################################
ARTIFACTORY_REGISTRY="${ARTIFACTORY_REGISTRY:-docker-snapshot.abc.def.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-abc/alpfr/analytics/datarobot/dr_11_1_8}"

################################################################################
# Usage
################################################################################
usage() {
    cat <<EOF
Usage:
    $0 <namespace> [--dry-run]

Arguments:
    namespace       Kubernetes namespace to scan for images

Options:
    --dry-run       Show what would be done without pulling/tagging/pushing
    -h, --help      Show this help message and exit

Environment Variables:
    ARTIFACTORY_REGISTRY   Target Artifactory registry host (default: docker-snapshot.abc.def.com)
    ARTIFACTORY_REPO       Target Artifactory docker repository (default: abc/alpfr/analytics/datarobot/dr_11_1_8)

Examples:
    $0 production
    $0 production --dry-run
EOF
    exit 1
}

################################################################################
# Argument Parsing
################################################################################
NAMESPACE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
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
            else
                echo "ERROR: Multiple namespaces specified: '$NAMESPACE' and '$1'" >&2
                usage
            fi
            ;;
    esac
    shift
done

if [[ -z "$NAMESPACE" ]]; then
    echo "ERROR: Namespace is a required argument." >&2
    usage
fi

################################################################################
# Prerequisite Verification
################################################################################
CONTAINER_CLI=""

check_prereqs() {
    local missing=0
    
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "ERROR: 'kubectl' command line tool is not installed or not in PATH." >&2
        missing=1
    fi
    
    # Detect docker or podman (highly common in Rocky Linux/RHEL)
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

verify_docker_login() {
    local registry="$1"
    local logged_in=false
    
    # Build list of possible authentication config paths for Docker and Podman
    local auth_files=()
    
    if [[ -n "${REGISTRY_AUTH_FILE:-}" ]]; then
        auth_files+=("$REGISTRY_AUTH_FILE")
    fi
    
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
        auth_files+=("${XDG_RUNTIME_DIR}/containers/auth.json")
    fi
    
    auth_files+=(
        "$HOME/.config/containers/auth.json"
        "${DOCKER_CONFIG:-$HOME/.docker}/config.json"
        "/run/user/$(id -u)/containers/auth.json"
    )
    
    # Check if the registry exists in any of the config files
    for config_file in "${auth_files[@]}"; do
        if [[ -f "$config_file" ]]; then
            if grep -q "\"${registry}\"" "$config_file" || grep -q "\"https://${registry}\"" "$config_file"; then
                logged_in=true
                break
            fi
        fi
    done
    
    if ! $logged_in; then
        if $DRY_RUN; then
            echo "WARNING: Not logged into Artifactory registry '${registry}' in any detected config files." >&2
            echo "         (Proceeding anyway because --dry-run is active)" >&2
        else
            echo "ERROR: Not logged into Artifactory registry '${registry}'." >&2
            echo "       Please login using: ${CONTAINER_CLI} login ${registry}" >&2
            exit 1
        fi
    fi
}

################################################################################
# Namespace Validation
################################################################################
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

################################################################################
# Target Tag Parsing (Extract Base Image Name)
################################################################################
get_target_image() {
    local source_image="$1"
    
    # 1. Extract the base image name (everything after the last slash)
    local base_image="${source_image##*/}"
    
    # 2. Handle image digests: docker tags cannot contain '@' or ':sha256:'
    # E.g. ubuntu@sha256:45b23d81... -> ubuntu:sha256-45b23d81...
    # If the reference already has a tag (like ubuntu:20.04@sha256:...), use -sha256-
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

################################################################################
# Main Execution
################################################################################
check_prereqs
verify_docker_login "$ARTIFACTORY_REGISTRY"
validate_namespace "$NAMESPACE"

echo "Collecting images from namespace '${NAMESPACE}' using ${CONTAINER_CLI}..."

# Use temporary files and ensure cleanup (portable across macOS and Linux)
TMP_IMAGES=$(mktemp -t k8s-images.XXXXXXXX)
TMP_MAPPING=$(mktemp -t k8s-mapping.XXXXXXXX)
trap 'rm -f "$TMP_IMAGES" "$TMP_MAPPING"' EXIT

# Extract container name and image mappings (including init, standard, and ephemeral containers)
kubectl get pods -n "$NAMESPACE" \
    -o jsonpath="{range .items[*]}{range .spec.initContainers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.containers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.ephemeralContainers[*]}{.name}{' '}{.image}{'\n'}{end}{end}" \
    | sort -u > "$TMP_MAPPING"

# Extract the list of unique images
awk '{print $2}' "$TMP_MAPPING" | sort -u > "$TMP_IMAGES"

IMAGE_COUNT=$(grep -cv '^$' "$TMP_IMAGES" || true)

if [[ ${IMAGE_COUNT} -eq 0 ]]; then
    echo "No images found in namespace '${NAMESPACE}'."
    exit 0
fi

echo
echo "Found ${IMAGE_COUNT} unique image(s):"
cat "$TMP_IMAGES"
echo

################################################################################
# Process Images
################################################################################
SUCCESS=0
FAILED=0

while read -r IMAGE; do
    [[ -z "$IMAGE" ]] && continue
    
    TARGET_IMAGE=$(get_target_image "$IMAGE")
    CONTAINERS=$(awk -v target="$IMAGE" '$2 == target { if (names == "") names = $1; else names = names ", " $1 } END { print names }' "$TMP_MAPPING")
    
    echo "========================================================"
    echo "Source     : ${IMAGE}"
    echo "Containers : ${CONTAINERS}"
    echo "Target     : ${TARGET_IMAGE}"
    
    if $DRY_RUN; then
        echo "[DRY-RUN] ${CONTAINER_CLI} pull ${IMAGE}"
        echo "[DRY-RUN] ${CONTAINER_CLI} tag ${IMAGE} ${TARGET_IMAGE}"
        echo "[DRY-RUN] ${CONTAINER_CLI} push ${TARGET_IMAGE}"
        SUCCESS=$((SUCCESS+1))
        continue
    fi
    
    if ! "$CONTAINER_CLI" pull "$IMAGE"; then
        echo "ERROR: Failed to pull $IMAGE"
        FAILED=$((FAILED+1))
        continue
    fi
    
    if ! "$CONTAINER_CLI" tag "$IMAGE" "$TARGET_IMAGE"; then
        echo "ERROR: Failed to tag $IMAGE as $TARGET_IMAGE"
        FAILED=$((FAILED+1))
        continue
    fi
    
    if "$CONTAINER_CLI" push "$TARGET_IMAGE"; then
        echo "SUCCESS: Pushed $TARGET_IMAGE"
        SUCCESS=$((SUCCESS+1))
    else
        echo "ERROR: Failed to push $TARGET_IMAGE"
        FAILED=$((FAILED+1))
    fi
done < "$TMP_IMAGES"

################################################################################
# Summary
################################################################################
echo
echo "==================== Summary ===================="
echo "Namespace      : ${NAMESPACE}"
echo "Dry Run        : ${DRY_RUN}"
echo "Images Found   : ${IMAGE_COUNT}"
echo "Succeeded      : ${SUCCESS}"
echo "Failed         : ${FAILED}"
echo "================================================="

if [[ ${FAILED} -gt 0 ]]; then
    exit 1
fi
