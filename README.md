# Copy Docker Images from Kubernetes to JFrog Artifactory

This project provides a robust bash script (`push-k8s-images.sh`) to extract all Docker images used in a given Kubernetes namespace, normalize and tag them, and push them to a private JFrog Artifactory registry.

## Features

- **Prerequisite Validation**: Verifies that both `kubectl` and `docker` are installed and in your environment `PATH`.
- **Active Login Verification**: Checks Docker configuration (`~/.docker/config.json`) to confirm that Docker is logged into your Artifactory registry before pulling or pushing images.
- **Namespace Checks**: Confirms that the target namespace exists in Kubernetes.
- **Dry-Run Mode**: Allows testing with the `--dry-run` flag to display the planned `docker pull`, `docker tag`, and `docker push` commands without executing them.
- **Preserves Directory Hierarchy**: Keeps the original image paths (such as namespaces, users, or registries) intact under the target registry path (using slashes `/`), avoiding naming collisions.
- **Port Normalization**: Replaces registry port colons (e.g. `localhost:5000` &rarr; `localhost_5000`) with underscores to ensure target tags conform to valid Docker reference formats.
- **Digest Translation**: Automatically maps image references utilizing digests (e.g., `image@sha256:...`) to valid tagged references (e.g., `image:sha256-...`) as Docker tags cannot contain `@` characters.
- **Summary Report**: Outputs execution statistics at the end of the run (images found, successes, failures).

## Prerequisites

- `bash` (compatible with standard v3.2+ on macOS/Linux)
- `kubectl` configured with access to your Kubernetes cluster
- `docker` daemon running locally and authenticated with your Artifactory registry

## Configuration

You can customize the target Artifactory registry and docker repository by setting the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `ARTIFACTORY_REGISTRY` | The domain name of the target Artifactory instance | `artifactory.example.com` |
| `ARTIFACTORY_REPO` | The target Docker registry repository name in Artifactory | `docker-local` |

## Usage

Make sure the script is executable:

```bash
chmod +x push-k8s-images.sh
```

### Dry Run (Recommended First Step)
Check what images are present in the namespace and preview the destination tags:

```bash
./push-k8s-images.sh production --dry-run
```

### Run Pushes
Perform the actual pull, tag, and push process:

```bash
# Using defaults
./push-k8s-images.sh production

# Specifying custom Artifactory target
ARTIFACTORY_REGISTRY="myjfrog.corp.com" ARTIFACTORY_REPO="docker-prod" ./push-k8s-images.sh production
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
