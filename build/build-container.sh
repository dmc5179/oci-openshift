#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-oci-openshift-deployer}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.15.8}"
OC_VERSION="${OC_VERSION:-4.22}"
OCI_CLI_VERSION="${OCI_CLI_VERSION:-3.90.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
if ! command -v "$CONTAINER_ENGINE" &>/dev/null; then
  CONTAINER_ENGINE="docker"
fi

echo "Building ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Terraform:  ${TERRAFORM_VERSION}"
echo "  OC client:  stable-${OC_VERSION}"
echo "  OCI CLI:    ${OCI_CLI_VERSION}"
echo "  Engine:     ${CONTAINER_ENGINE}"
echo ""

"$CONTAINER_ENGINE" build --squash-all \
  --build-arg TERRAFORM_VERSION="${TERRAFORM_VERSION}" \
  --build-arg OC_VERSION="${OC_VERSION}" \
  --build-arg OCI_CLI_VERSION="${OCI_CLI_VERSION}" \
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
