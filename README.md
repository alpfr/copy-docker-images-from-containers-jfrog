# Copy Docker Images from Kubernetes to JFrog Artifactory

This repository contains robust bash utility scripts to extract Docker/Podman images used in a given Kubernetes namespace, normalize and tag them, and push them to a private JFrog Artifactory registry.

These scripts are highly optimized to run portably on **macOS** and **Linux** platforms, including RHEL-based distributions like **Rocky Linux**.

---

## 1. Extract & Copy All Images in a Namespace (`push-k8s-images.sh`)

This script extracts **all** unique images across all pods (standard, init, and ephemeral containers) in a given namespace, and pushes them to Artifactory sequentially.

### Usage

```bash
./push-k8s-images.sh <namespace> [--dry-run]
```

* **Dry Run**: Check what images are present in the namespace and preview the destination tags without making modifications:
  ```bash
  ./push-k8s-images.sh production --dry-run
  ```
* **Execute copy**:
  ```bash
  ./push-k8s-images.sh production
  ```

---

## 2. Extract & Copy a Specific Container's Image (`push-k8s-container-image.sh`)

This script targets and copies **only** the image of a specific container name within a namespace (scanning standard, init, and ephemeral containers).

### Usage

```bash
./push-k8s-container-image.sh <namespace> <container_name> [--dry-run]
```

* **Dry Run**: Check the image of a specific container and preview the tag without making modifications:
  ```bash
  ./push-k8s-container-image.sh production web --dry-run
  ```
* **Execute copy**:
  ```bash
  ./push-k8s-container-image.sh production web
  ```

---

## 3. Advanced Parallel Image Copying (`push-k8s-images-advanced.sh`) [RECOMMENDED]

This script is built for production environments and namespaces containing many pods/images. It adds concurrency, retries, sidecar filtering, and environment loading features.

### Advanced Features
* **Parallel Processing**: Runs image pulls and pushes concurrently using a background job pool. Set the maximum concurrent jobs with `-j` or `--jobs` (default is `3`).
* **Auto-Retries**: Automatically retries failing pull or push commands using exponential backoff. Set the max attempts with `-r` or `--retries` (default is `3`).
* **Container Exclusions**: Ignores common system sidecars (like `istio-proxy`, `vault-agent`, `linkerd-proxy`, `datadog-agent`) by default, and accepts custom filters via `-e` or `--exclude`.
* **Safe Log Synchronization**: Suppresses interleaved outputs from parallel background jobs by capturing logs individually and printing them sequentially when each job finishes.
* **`.env` Configuration File**: Automatically loads environment variables from a `.env` file in the current directory if it exists.

### Usage

```bash
./push-k8s-images-advanced.sh <namespace> [options]
```

* **Dry Run**:
  ```bash
  ./push-k8s-images-advanced.sh production --dry-run
  ```
* **Run with custom jobs (5) and retries (4) while excluding specific containers**:
  ```bash
  ./push-k8s-images-advanced.sh production -j 5 -r 4 --exclude "nginx,istio-proxy"
  ```

---

## Configuration

You can customize the target Artifactory registry and docker repository by setting the following environment variables (which can also be defined inside a local `.env` file):

| Variable | Description | Default |
|----------|-------------|---------|
| `ARTIFACTORY_REGISTRY` | The domain name of the target Artifactory instance | `docker-snapshot.abc.def.com` |
| `ARTIFACTORY_REPO` | The target Docker registry repository name in Artifactory | `abc/alpfr/analytics/datarobot/dr_11_1_8` |

Example `.env` file:
```env
ARTIFACTORY_REGISTRY=docker-snapshot.abc.def.com
ARTIFACTORY_REPO=abc/alpfr/analytics/datarobot/dr_11_1_8
```

## How Tag Mapping Works

Source images are mapped directly to the target repository folder using their base image name:

| Source Reference | Target Reference |
|------------------|------------------|
| `nginx:1.29` | `docker-snapshot.abc.def.com/abc/alpfr/analytics/datarobot/dr_11_1_8/nginx:1.29` |
| `company/app:v2.5.1` | `docker-snapshot.abc.def.com/abc/alpfr/analytics/datarobot/dr_11_1_8/app:v2.5.1` |
| `ghcr.io/company/app:v2.5.1` | `docker-snapshot.abc.def.com/abc/alpfr/analytics/datarobot/dr_11_1_8/app:v2.5.1` |
| `localhost:5000/app:1.0` | `docker-snapshot.abc.def.com/abc/alpfr/analytics/datarobot/dr_11_1_8/app:1.0` |
| `ubuntu@sha256:45b23d811c` | `docker-snapshot.abc.def.com/abc/alpfr/analytics/datarobot/dr_11_1_8/ubuntu:sha256-45b23d811c` |
| company/app:v2.5.1@sha256:45b23d811c | `docker-snapshot.abc.def.com/abc/alpfr/analytics/datarobot/dr_11_1_8/app:v2.5.1-sha256-45b23d811c` |

---

## 4. Local Image Cleanup (`cleanup-k8s-container-image.sh`)

This script scans Kubernetes pods in a namespace for a specific container (or all containers), identifies their local images and their Artifactory target tags, and removes them from the host's container runtime to free up disk space or force a fresh pull.

### Usage
```bash
./cleanup-k8s-container-image.sh -n <namespace> [options]
```

* **Dry Run**: Preview what images would be removed without actually purging them:
  ```bash
  ./cleanup-k8s-container-image.sh -n production -c web --dry-run
  ```
* **Clean up specific container (e.g. `web`) inside namespace `production` using `podman`**:
  ```bash
  ./cleanup-k8s-container-image.sh -n production -c web -v podman
  ```
* **Clean up all containers in namespace `production` using Containered/`crictl`**:
  ```bash
  ./cleanup-k8s-container-image.sh -n production -c all -v crictl
  ```
