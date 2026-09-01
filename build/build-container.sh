#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-oci-openshift-deployer}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.15.8}"
OC_VERSION="${OC_VERSION:-4.22}"
OCI_CLI_VERSION="${OCI_CLI_VERSION:-3.90.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect the git repo URL and branch from the repo this script lives in
GIT_REMOTE_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)"
GIT_BRANCH="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
# Fall back to 'main' if HEAD is detached (rev-parse returns literal "HEAD")
if [[ "$GIT_BRANCH" == "HEAD" || -z "$GIT_BRANCH" ]]; then
  GIT_BRANCH="main"
fi

# Convert SSH remote URLs to HTTPS so the container build can clone without SSH keys
if [[ "$GIT_REMOTE_URL" =~ ^git@([^:]+):(.+)$ ]]; then
  GIT_REMOTE_URL="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
fi

GIT_REPO_URL="${GIT_REPO_URL:-$GIT_REMOTE_URL}"
GIT_REPO_BRANCH="${GIT_REPO_BRANCH:-$GIT_BRANCH}"

CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
if ! command -v "$CONTAINER_ENGINE" &>/dev/null; then
  CONTAINER_ENGINE="docker"
fi

echo "Building ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Terraform:  ${TERRAFORM_VERSION}"
echo "  OC client:  stable-${OC_VERSION}"
echo "  OCI CLI:    ${OCI_CLI_VERSION}"
echo "  Git repo:   ${GIT_REPO_URL}"
echo "  Git branch: ${GIT_REPO_BRANCH}"
echo "  Engine:     ${CONTAINER_ENGINE}"
echo ""

"$CONTAINER_ENGINE" build --squash-all \
  --build-arg TERRAFORM_VERSION="${TERRAFORM_VERSION}" \
  --build-arg OC_VERSION="${OC_VERSION}" \
  --build-arg OCI_CLI_VERSION="${OCI_CLI_VERSION}" \
  --build-arg GIT_REPO_URL="${GIT_REPO_URL}" \
  --build-arg GIT_REPO_BRANCH="${GIT_REPO_BRANCH}" \
  -t "${IMAGE_NAME}:${IMAGE_TAG}" \
  -f "${SCRIPT_DIR}/Containerfile" \
  "${SCRIPT_DIR}"

echo ""
echo "Built: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "Run interactively:"
echo "  ${CONTAINER_ENGINE} run -it --rm \\"
echo "    -v \${HOME}/.oci:/root/.oci:ro \\"
echo "    -v \${HOME}/.ssh:/root/.ssh:ro \\"
echo "    -v /path/to/openshift-on-oci.tfvars:/opt/oci-openshift/openshift-on-oci.tfvars:ro \\"
echo "    ${IMAGE_NAME}:${IMAGE_TAG}"
