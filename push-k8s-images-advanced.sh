#!/bin/bash

set -euo pipefail

################################################################################
# Configuration Defaults
################################################################################
ARTIFACTORY_REGISTRY="artifactory.example.com"
ARTIFACTORY_REPO="docker-local"

################################################################################
# Load .env File if present (safely parses key=value pairs)
################################################################################
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
ARTIFACTORY_REGISTRY="${ARTIFACTORY_REGISTRY:-artifactory.example.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-docker-local}"

################################################################################
# Usage
################################################################################
usage() {
    cat <<EOF
Usage:
    $0 <namespace> [options]

Arguments:
    namespace       Kubernetes namespace to scan for images

Options:
    -j, --jobs NUM      Maximum concurrent pull/tag/push jobs (default: 3)
    -r, --retries NUM   Number of retries for failed pull/push operations (default: 3)
    -e, --exclude LIST  Comma-separated list of container names to exclude
                        (default: istio-proxy,linkerd-proxy,vault-agent,datadog-agent)
    --dry-run           Show what would be done without pulling/tagging/pushing
    -h, --help          Show this help message and exit

Environment Variables (can also be specified in a local .env file):
    ARTIFACTORY_REGISTRY   Target Artifactory registry host (default: artifactory.example.com)
    ARTIFACTORY_REPO       Target Artifactory docker repository (default: docker-local)

Examples:
    $0 production
    $0 production -j 5 -r 5
    $0 production --exclude "nginx,vault-agent" --dry-run
EOF
    exit 1
}

################################################################################
# Argument Parsing
################################################################################
NAMESPACE=""
JOBS=3
RETRIES=3
EXCLUDES="istio-proxy,linkerd-proxy,vault-agent,datadog-agent"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j|--jobs)
            if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                echo "ERROR: --jobs requires a positive integer argument." >&2
                usage
            fi
            JOBS="$2"
            shift
            ;;
        -r|--retries)
            if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                echo "ERROR: --retries requires a non-negative integer argument." >&2
                usage
            fi
            RETRIES="$2"
            shift
            ;;
        -e|--exclude)
            if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                echo "ERROR: --exclude requires a comma-separated list of container names." >&2
                usage
            fi
            EXCLUDES="$2"
            shift
            ;;
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

# Concurrency and retry bounds checks
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --jobs must be a positive integer." >&2
    exit 1
fi
if ! [[ "$RETRIES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --retries must be a non-negative integer." >&2
    exit 1
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
# Target Tag Parsing (Preserve Path Structure)
################################################################################
get_target_image() {
    local source_image="$1"
    
    # 1. Handle image digests: docker tags cannot contain '@' or ':sha256:'
    local normalized_ref="$source_image"
    if [[ "$normalized_ref" == *@sha256:* ]]; then
        local base_part="${normalized_ref%%@*}"
        if [[ "$base_part" == *:* ]]; then
            normalized_ref=$(echo "$normalized_ref" | sed 's/@sha256:/-sha256-/')
        else
            normalized_ref=$(echo "$normalized_ref" | sed 's/@sha256:/:sha256-/')
        fi
    fi

    # 2. Extract Registry and Repository Path
    local registry=""
    local repo_path=""
    
    if [[ "$normalized_ref" == */* ]]; then
        local first_part
        first_part=$(echo "$normalized_ref" | cut -d'/' -f1)
        
        # A first segment is a registry if it has a '.' or ':' or equals 'localhost'
        if [[ "$first_part" == *.* || "$first_part" == *:* || "$first_part" == "localhost" ]]; then
            registry="$first_part"
            repo_path=$(echo "$normalized_ref" | cut -d'/' -f2-)
        else
            registry="docker.io"
            repo_path="$normalized_ref"
        fi
    else
        registry="docker.io"
        repo_path="library/$normalized_ref"
    fi
    
    # 3. Clean registry part to remove port colon if present (colons not allowed in repository path)
    local clean_registry
    clean_registry=$(echo "$registry" | tr ':' '_')
    
    echo "${ARTIFACTORY_REGISTRY}/${ARTIFACTORY_REPO}/${clean_registry}/${repo_path}"
}

################################################################################
# Command Retry Executor (Exponential Backoff)
################################################################################
run_with_retry() {
    local max_retries="$1"
    shift
    local cmd=("$@")
    local attempt=1
    local delay=2
    
    while true; do
        if "${cmd[@]}"; then
            return 0
        fi
        
        if [[ $attempt -ge $max_retries ]]; then
            echo "ERROR: Command failed after $attempt attempt(s): ${cmd[*]}" >&2
            return 1
        fi
        
        echo "WARNING: Command failed. Retrying in ${delay}s (Attempt $((attempt+1))/$max_retries)..." >&2
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
}

################################################################################
# Subprocess Image Worker
################################################################################
process_single_image() {
    local img="$1"
    local target_img="$2"
    local log_f="$3"
    local status_f="$4"
    local containers="$5"
    
    {
        echo "========================================================"
        echo "Source     : ${img}"
        echo "Containers : ${containers}"
        echo "Target     : ${target_img}"
        
        if $DRY_RUN; then
            echo "[DRY-RUN] ${CONTAINER_CLI} pull ${img}"
            echo "[DRY-RUN] ${CONTAINER_CLI} tag ${img} ${target_img}"
            echo "[DRY-RUN] ${CONTAINER_CLI} push ${target_img}"
            echo 0 > "$status_f"
            exit 0
        fi
        
        # 1. Pull with Retry
        if ! run_with_retry "$RETRIES" "$CONTAINER_CLI" pull "$img"; then
            echo "ERROR: Failed to pull ${img}" >&2
            echo 1 > "$status_f"
            exit 1
        fi
        
        # 2. Tag
        if ! "$CONTAINER_CLI" tag "$img" "$target_img"; then
            echo "ERROR: Failed to tag ${img} as ${target_img}" >&2
            echo 1 > "$status_f"
            exit 1
        fi
        
        # 3. Push with Retry
        if ! run_with_retry "$RETRIES" "$CONTAINER_CLI" push "$target_img"; then
            echo "ERROR: Failed to push ${target_img}" >&2
            echo 1 > "$status_f"
            exit 1
        fi
        
        echo "SUCCESS: Pushed ${target_img}"
        echo 0 > "$status_f"
        exit 0
    } > "$log_f" 2>&1
}

################################################################################
# Main Execution
################################################################################
check_prereqs
verify_docker_login "$ARTIFACTORY_REGISTRY"
validate_namespace "$NAMESPACE"

echo "Collecting images from namespace '${NAMESPACE}' using ${CONTAINER_CLI}..."
if [[ -n "$EXCLUDES" ]]; then
    echo "Excluding containers: ${EXCLUDES}"
fi

# Portable temporary workspace directory for job tracking and log isolation
TMP_DIR=$(mktemp -d -t k8s-images-advanced.XXXXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

## Extract all images, filter exclusions, and keep container name mappings
kubectl get pods -n "$NAMESPACE" \
    -o jsonpath="{range .items[*]}{range .spec.initContainers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.containers[*]}{.name}{' '}{.image}{'\n'}{end}{range .spec.ephemeralContainers[*]}{.name}{' '}{.image}{'\n'}{end}{end}" \
    | awk -v excludes_str="$EXCLUDES" '
        BEGIN {
            split(excludes_str, arr, ",");
            for (key in arr) {
                excludes[arr[key]] = 1;
            }
        }
        {
            if (!excludes[$1]) {
                print $0;
            }
        }' \
    | sort -u > "${TMP_DIR}/mapping.txt"

# Extract unique image list
awk '{print $2}' "${TMP_DIR}/mapping.txt" | sort -u > "${TMP_DIR}/images.txt"

IMAGE_COUNT=$(grep -cv '^$' "${TMP_DIR}/images.txt" || true)

if [[ ${IMAGE_COUNT} -eq 0 ]]; then
    echo "No images found in namespace '${NAMESPACE}' matching current filter rules."
    exit 0
fi

echo "Found ${IMAGE_COUNT} unique image(s) to copy."
echo "Starting transfer with maximum concurrency: ${JOBS} job(s), ${RETRIES} retry attempt(s)..."
echo

################################################################################
# Parallel Processing Loop
################################################################################
pids=()
log_files=()
status_files=()

active_pids=()

wait_for_job_space() {
    while [[ ${#active_pids[@]} -ge $JOBS ]]; do
        local temp_pids=()
        for pid in "${active_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                temp_pids+=("$pid")
            else
                # Process finished, reap exit status
                wait "$pid"
            fi
        done
        active_pids=("${temp_pids[@]}")
        if [[ ${#active_pids[@]} -ge $JOBS ]]; then
            sleep 0.2
        fi
    done
}

index=0
while read -r IMAGE; do
    [[ -z "$IMAGE" ]] && continue
    
    TARGET_IMAGE=$(get_target_image "$IMAGE")
    CONTAINERS=$(awk -v target="$IMAGE" '$2 == target { if (names == "") names = $1; else names = names ", " $1 } END { print names }' "${TMP_DIR}/mapping.txt")
    
    log_file="${TMP_DIR}/job_${index}.log"
    status_file="${TMP_DIR}/job_${index}.status"
    
    # Store arrays
    log_files+=("$log_file")
    status_files+=("$status_file")
    
    # Wait for space in concurrency pool
    wait_for_job_space
    
    # Spawn background job
    process_single_image "$IMAGE" "$TARGET_IMAGE" "$log_file" "$status_file" "$CONTAINERS" &
    pid=$!
    
    pids+=("$pid")
    active_pids+=("$pid")
    
    index=$((index + 1))
done < "${TMP_DIR}/images.txt"

# Wait for remaining background jobs to finish
for pid in "${active_pids[@]}"; do
    wait "$pid"
done

################################################################################
# Process and Synchronize Output Logs
################################################################################
SUCCESS=0
FAILED=0

for i in "${!pids[@]}"; do
    if [[ -f "${log_files[$i]}" ]]; then
        cat "${log_files[$i]}"
    fi
    
    status=$(cat "${status_files[$i]}" 2>/dev/null || echo 1)
    if [[ "$status" -eq 0 ]]; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

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
