# Setting Up a Connected RHEL 9 Bastion on OCI

How to prepare an internet-connected RHEL 9 VM on OCI to run this repo's
terraform. For a bastion with no internet access, prepare the tools on a
connected host instead and follow [terraform-offline-init.md](terraform-offline-init.md).

## 1. Launch the VM

Any RHEL 9 VM on OCI works: a Marketplace RHEL image, or an imported KVM guest
image. The default SSH user is `opc` for Marketplace images and `cloud-user`
for imported KVM guest images.

To create your own user at launch, pass cloud-init as the instance's user data:

```yaml
#cloud-config
users:
  - name: admin
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...your-public-key...
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
```

For an install with `enable_fips = true`, the bastion must itself run in FIPS
mode. Red Hat recommends enabling FIPS mode when the system is installed rather
than switching an existing system. See
[disconnected-bastion-setup.md](disconnected-bastion-setup.md).

## 2. Register RHEL

If the image is not already set up for updates, as with bring-your-own-
subscription images and imported guest images, register the system:

```bash
sudo subscription-manager register --username <rhn_username>
sudo subscription-manager repos \
  --enable=rhel-9-for-x86_64-baseos-rpms \
  --enable=rhel-9-for-x86_64-appstream-rpms
```

With Simple Content Access, which Red Hat now applies to every organization,
registering is enough; there is no subscription to attach.

Install the utilities the scripts in this repo use:

```bash
sudo dnf install -y git jq tar unzip bind-utils
```

## 3. Install and configure the OCI CLI

Oracle's installer puts the CLI in your home directory and needs no root:

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- \
  --accept-all-defaults
exec -l "$SHELL"
oci --version
```

Then authenticate, one of two ways.

**API key.** Run `oci setup config`. It asks for your tenancy OCID, user OCID
and region, and writes a key pair to `~/.oci/`. Upload the public key in the
console under **Identity & Security → Users → your user → API Keys → Add API
Key**.

**Instance principal.** If the bastion is in a dynamic group with the IAM
policies it needs, skip the key and set:

```bash
export OCI_CLI_AUTH=instance_principal
```

Either way, check it works:

```bash
oci iam region list --output table
```

In a non-commercial realm whose API endpoints use their own certificate
authority, the CLI also needs that CA: see
[disconnected-prerequisites.md](disconnected-prerequisites.md#realms-with-their-own-certificate-authority).

## 4. Install Terraform

From HashiCorp's RPM repository:

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y terraform
terraform version
```

Terraform downloads the providers the stacks need on the first `terraform init`
in each stack. There is nothing to install for them separately.

## 5. Get this repo

```bash
git clone https://github.com/oracle-quickstart/oci-openshift.git
cd oci-openshift
```

## 6. Create the resource attribution tags

Once per tenancy, before the first cluster:

```bash
cd terraform-stacks/create-resource-attribution-tags
terraform init
terraform apply \
  -var="tenancy_ocid=<tenancy_ocid>" \
  -var="tag_namespace_compartment_ocid_resource_tagging=<compartment_ocid>"
```

Instance role tags do not need a separate step: the create-cluster stack
creates them along with the cluster. The `create-instance-role-tags` stack is
only for sharing one set across clusters, with `use_existing_tags = true`.

## 7. Next

- Disconnected install: [disconnected-bastion-setup.md](disconnected-bastion-setup.md)
- Isolated realm such as OC6: [oc6-quickstart.md](oc6-quickstart.md)
- Variables: copy `openshift-on-oci.tfvars.template` to `openshift-on-oci.tfvars`
  and fill it in. Each variable is described there and in
  `terraform-stacks/create-cluster/variables.tf`.
