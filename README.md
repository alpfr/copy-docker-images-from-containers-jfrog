# Copy Docker Images from Kubernetes to JFrog Artifactory

This repository contains robust bash utility scripts to extract Docker/Podman images used in a given Kubernetes namespace, normalize and tag them, and push them to a private JFrog Artifactory registry.

These scripts are highly optimized to run portably on **macOS** and **Linux** platforms, including RHEL-based distributions like **Rocky Linux**.

---

## 1. Extract & Copy All Images in a Namespace (`push-k8s-images.sh`)

This script extracts **all** unique images across all pods (standard, init, and ephemeral containers) in a given namespace, and pushes them to Artifactory.

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

## Features

- **Multi-Runtime Container Support**: Automatically detects and leverages `docker` or `podman` (default in Rocky Linux) container engines.
- **Prerequisite Validation**: Verifies that `kubectl` and either `docker` or `podman` are installed and in your environment `PATH`.
- **Multi-Path Login Verification**: Checks Docker and Podman configuration directories (e.g. `~/.docker/config.json`, `~/.config/containers/auth.json`, and dynamic user runtime auth structures `${XDG_RUNTIME_DIR}`) to confirm registry authentication before starting.
- **Namespace Checks**: Confirms that the target namespace exists in Kubernetes.
- **Preserves Directory Hierarchy**: Keeps the original image paths (such as namespaces, users, or registries) intact under the target registry path (using slashes `/`), avoiding naming collisions.
- **Port Normalization**: Replaces registry port colons (e.g. `localhost:5000` &rarr; `localhost_5000`) with underscores to ensure target tags conform to valid Docker reference formats.
- **Digest Translation**: Automatically maps image references utilizing digests (e.g., `image@sha256:...`) to valid tagged references (e.g., `image:sha256-...`) as Docker tags cannot contain `@` characters.
- **Summary Report**: Outputs execution statistics at the end of the run (images found, successes, failures).

## Configuration

You can customize the target Artifactory registry and docker repository by setting the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `ARTIFACTORY_REGISTRY` | The domain name of the target Artifactory instance | `artifactory.example.com` |
| `ARTIFACTORY_REPO` | The target Docker registry repository name in Artifactory | `docker-local` |

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
