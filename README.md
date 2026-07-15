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
| `ARTIFACTORY_REGISTRY` | The domain name of the target Artifactory instance | `artifactory.example.com` |
| `ARTIFACTORY_REPO` | The target Docker registry repository name in Artifactory | `docker-local` |

Example `.env` file:
```env
ARTIFACTORY_REGISTRY=jfrog.company.com
ARTIFACTORY_REPO=docker-production
```

## How Tag Mapping Works

Source images are mapped to target paths in the registry to prevent any collisions:

| Source Reference | Target Reference |
|------------------|------------------|
| `nginx:1.29` | `artifactory.example.com/docker-local/docker.io/library/nginx:1.29` |
| `company/app:v2.5.1` | `artifactory.example.com/docker-local/docker.io/company/app:v2.5.1` |
| `ghcr.io/company/app:v2.5.1` | `artifactory.example.com/docker-local/ghcr.io/company/app:v2.5.1` |
| `localhost:5000/app:1.0` | `artifactory.example.com/docker-local/localhost_5000/app:1.0` |
| `ubuntu@sha256:45b23d811c` | `artifactory.example.com/docker-local/docker.io/library/ubuntu:sha256-45b23d811c` |
| `company/app:v2.5.1@sha256:45b23d811c` | `artifactory.example.com/docker-local/docker.io/company/app:v2.5.1-sha256-45b23d811c` |
