# OCI OpenShift Deployer Container

Self-contained container image for deploying OpenShift on OCI. Packages the
full terraform stack, OCI CLI, OpenShift client, and all terraform provider
plugins so deploys work without internet access to provider registries.

## What's inside

| Tool | Version | Purpose |
|------|---------|---------|
| terraform | 1.15.8 | Infrastructure provisioning |
| oci-cli | 3.90.1 | OCI API operations (Object Storage, Marketplace, etc.) |
| oc / kubectl | stable-4.22 | OpenShift / Kubernetes CLI |
| python3 | UBI9 default | OCI CLI runtime |
| jq | UBI9 default | JSON processing (used by userdata scripts) |
| make | UBI9 default | Makefile targets |
| openssh-clients | UBI9 default | SSH to bastion and cluster nodes |

### Pre-cached Terraform providers

All providers are downloaded during the image build so `terraform init` does
not require internet access at runtime:

| Provider | Version |
|----------|---------|
| oracle/oci | >= 6.12.0 |
| hashicorp/time | >= 0.12.1 |
| hashicorp/external | ~> 2.3 |

## Build

```bash
./build-container.sh
```

Override defaults with environment variables:

```bash
TERRAFORM_VERSION=1.15.8 \
OC_VERSION=4.22 \
OCI_CLI_VERSION=3.90.1 \
IMAGE_NAME=oci-openshift-deployer \
IMAGE_TAG=v1 \
  ./build-container.sh
```

Use `CONTAINER_ENGINE=docker` if podman is not available.

## Run

```bash
podman run -d --rm --name oci-terraform \
  --entrypoint '["bash", "-c", "sleep infinity"]' \
  -v /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem:/etc/pki/tls/certs/ca-bundle.crt:ro,z \
  -v ${HOME}/.oci:/home/appuser/.oci:ro,Z,U \
  -v ${HOME}/.ssh:/home/appuser/.ssh:ro,Z,U \
  -v /home/danclark/workspace/openshift-on-oci/oci-openshift-mine/openshift-on-oci.tfvars:/opt/oci-openshift/openshift-on-oci.tfvars:ro,Z,U \
  -v /home/danclark/Downloads/pull-secret:/opt/oci-openshift/pull-secret.json:ro,Z,U \
  quay.io/danclark/oci-openshift-deployer:latest
```



### Volume mounts

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `~/.oci/` | `/root/.oci` | OCI API key and config |
| `~/.ssh/` | `/root/.ssh` | SSH keys for bastion and node access |
| `openshift-on-oci.tfvars` | `/opt/oci-openshift/openshift-on-oci.tfvars` | Terraform variables (sensitive) |
| `pull-secret.json` | `/opt/oci-openshift/pull-secret.json` | Red Hat pull secret |

### Terraform state

Terraform state is ephemeral inside the container. To persist state across
runs, mount the working directory or use a remote backend:

```bash
podman run -it --rm \
  -v ${HOME}/.oci:/root/.oci:ro \
  -v $(pwd)/tf-state:/opt/oci-openshift/terraform-stacks/create-cluster/terraform.tfstate.d \
  oci-openshift-deployer:latest
```

## Disconnected / air-gapped use

The container image includes pre-cached terraform providers. For a fully
disconnected deploy:

1. Build the image on a connected host
2. Save and transfer: `podman save oci-openshift-deployer:latest | gzip > deployer.tar.gz`
3. Load on the air-gapped host: `podman load < deployer.tar.gz`
4. The OCI-specific container images (CCM, CSI, etc.) still need to be
   mirrored — see the `imageset-config.yaml` and oc-mirror workflow below.

## OCI-specific container images

The OpenShift-on-OCI deployment uses these container images beyond the
standard OpenShift release payload. They must be mirrored to your disconnected
registry for air-gapped installs:

| Image | Used by |
|-------|---------|
| `ghcr.io/oracle/cloud-provider-oci:v1.34.0` | OCI Cloud Controller Manager (CCM) DaemonSet |
| `registry.k8s.io/sig-storage/csi-provisioner:v5.0.1` | OCI CSI driver |
| `registry.k8s.io/sig-storage/csi-attacher:v4.6.1` | OCI CSI driver |
| `registry.k8s.io/sig-storage/csi-resizer:v1.11.1` | OCI CSI driver |
| `registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.12.0` | OCI CSI driver |
| `registry.k8s.io/sig-storage/csi-snapshotter:v6.3.0` | OCI CSI driver |
| `registry.k8s.io/sig-storage/snapshot-controller:v6.3.0` | OCI CSI driver |
| `quay.io/openshift/origin-cli:4.20` | CCM init container |
| `$OCA_IMAGE_URL` (from OCIR) | Oracle Cloud Agent (optional, not available in Gov Cloud) |
