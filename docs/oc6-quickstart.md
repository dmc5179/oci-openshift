# Quick Start: OpenShift on OCI (Any Realm)

Seven steps to deploy OpenShift 4.22 on a fresh OCI environment using agent-based installation. Works for any realm (OC1, OC3, OC6, etc.) — the realm domain is auto-detected from IMDS on the bastion.

**Prerequisites:** OCI API keys configured, `oci` CLI installed, `openshift-install` (or `openshift-install-fips`) available. For non-commercial realms (e.g., OC6), ensure `~/.oci/regions-config.json` is configured so the OCI CLI can reach the correct endpoints.

---

1. **Create your tfvars** — `cp openshift-on-oci.tfvars.template openshift-on-oci.tfvars` and fill in `tenancy_ocid`, `compartment_ocid`, `region`, `cluster_name`, `zone_dns`, `public_ssh_key`, and tag namespace fields. Set `create_openshift_instances = false`.

2. **Create resource attribution tags** — `cd terraform-stacks/create-resource-attribution-tags && terraform init && terraform apply`. Required before the cluster stack.

3. **Terraform pass 1 (infra only)** — `cd terraform-stacks/create-cluster && terraform init && terraform apply -var-file=../../openshift-on-oci.tfvars -var='create_openshift_instances=false'`. Creates VCN, subnets, LBs, DNS, Object Storage bucket, and PARs for both rootfs and ISO.

4. **Extract manifests** — `./scripts/generate-ocp-artifacts.sh`. Writes `agent-config.yaml`, `install-config.yaml`, and all 10 OCI day-0 manifests (CCM, CSI, network) into the installer directory. **Do not skip this step.**

5. **Create the agent ISO** — `cd ~/ocp-deployment-agentBasedInstallation && openshift-install agent create image --dir=.` (use `openshift-install-fips` for FIPS). Bakes OCI manifests into the ISO and produces rootfs in `boot-artifacts/`.

6. **Terraform pass 2 (create instances)** — `terraform apply -var-file=../../openshift-on-oci.tfvars -var='create_openshift_instances=true' -var='iso_file_path=<path>/agent.x86_64.iso' -var='rootfs_file_path=<path>/boot-artifacts/agent.x86_64-rootfs.img'`. Terraform uploads both files to Object Storage and imports the ISO as a custom image. No manual PAR handling needed.

7. **Monitor the install** — `export KUBECONFIG=~/ocp-deployment-agentBasedInstallation/auth/kubeconfig && watch 'oc get nodes; oc get clusterversion; oc get co'`. Takes ~30-45 min. If using a bastion with VCN peering, run `./scripts/add-bastion-peering-route.sh` first.
