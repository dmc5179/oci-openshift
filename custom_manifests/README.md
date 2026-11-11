# Custom Manifests

These OpenShift and Kubernetes manifest files support the installation of Red Hat OpenShift clusters on Oracle Cloud Infrastructure. The Butane files used to generate the OpenShift MachineConfigs are also included.

Choose CCM and CSI manifests using the [OpenShift / Kubernetes / OCI driver compatibility matrix](../README.md#version-compatibility). Versioned manifests for `v1.36.0`, `v1.35.0`, and `v1.34.0` are available under [oci-ccm-csi-drivers](./oci-ccm-csi-drivers/). Use both driver manifests from the same version directory when installing manually. For Terraform installations, the `oci_driver_version` selection controls both drivers in `dynamic_custom_manifest`.

View usage during [installation](/README.md#documentation-and-installation-instructions)


## Individual Manifests
| File | Description | When to Use |
--- | --- | ---
**01-oci-ccm.yml** | Cluster resources for OCI Cloud Controller Manager (CCM). | Always ✅
**01-oci-csi.yml** | Cluster resources for OCI Container Storage Interface (CSI). See [STORAGE.md](~/docs/STORAGE.md) | Always ✅
**01-oci-driver-configs.yml** | Configuration Secrets for CCM and CSI drivers. ❗**Contains placeholder values that need to be replaced before use.** | Always ✅
**02-machineconfig-ccm.yml** | MachineConfig that fetches the provider (OCI) id for kubelet from the OCI metadata of the instance. | Always ✅
**02-machineconfig-csi.yml** | MachineConfig that enables the iscsid.service to run. | Always ✅
**03-machineconfig-consistent-device-path.yml** | MachineConfig that ensures consistent device paths when attaching paravirtualized volumes to instances. | Always ✅
**04-cluster-network.yml** | Cluster resource that configures the default Network's internalMasqueradeSubnet to 169.254.64.0/18 to avoid collisions with iSCSI boot volumes. |Required when using Bare Metal instances with OpenShift versions >= 4.17
**05-oci-eval-user-data.yml** | MachineConfig that evaluates and runs [userdata scripts](/terraform-stacks/shared_modules/compute/userdata/) stored in the metadata of instances. | Required when using Bare Metal instances
**06-oci-oca.yml** | Cluster resources for Oracle Cloud Agent on OpenShift nodes. See [oracle-cloud-agent.md](/docs/oracle-cloud-agent.md). | Optional
**08-autoscaling-operator.yml** | Bootstrap manifest for the OCI OpenShift Autoscaler operator namespace, activation job, and initial operator install flow. | Required when enabling OCI OpenShift Autoscaler
**09-autoscaling-operator-runtime.yml** | Runtime manifest applied by the autoscaler activation job to install the OCI CAPI operator controller, RBAC, CRD, and provider installer resources. | Required when enabling OCI OpenShift Autoscaler
**10-autoscaling-operator-configs.yml** | Configuration template for autoscaler operator, CAPI, CAPOCI, Cluster Autoscaler, OCI networking, image, and node-pool settings. | Required when enabling OCI OpenShift Autoscaler

Previously, the `oci_ccm_config` output from the OCI Resource Manager Stack (RMS) job was used to replace configuration values in `manifests/01-oci-ccm.yml` and `manifests/01-oci-csi.yml`, and then all required manifests were uploaded individually during cluster creation. This workflow is still valid, but the configuration values to be replaced are now located in [manifests/01-oci-driver-configs.yml](./manifests/01-oci-driver-configs.yml).

### Individual Manifest Outputs (Agent-based Installer)
---
The `create-cluster` stack provides an individual terraform output for each manifest. Written one per file into the agent-based installer's `openshift/` directory, they are equivalent to the `dynamic_custom_manifest` output below. `scripts/generate-ocp-artifacts.sh` writes all of them, skipping the optional ones your settings leave null, and fails if a required one is missing. To do it by hand:

```bash
mkdir -p openshift
for m in manifest_oci_ccm manifest_oci_csi manifest_oci_ccm_config manifest_oci_csi_config \
         manifest_machineconfig_ccm manifest_machineconfig_csi manifest_machineconfig_device_path \
         manifest_cluster_network manifest_machineconfig_eval_user_data; do
  terraform output -raw "$m" > "openshift/${m}.yaml"
done
# Optional: null unless enabled, in which case terraform output -raw fails.
for m in manifest_image_tag_mirror_set manifest_oci_custom_ca manifest_oca \
         manifest_autoscaler_operator manifest_autoscaler_runtime_configmap; do
  terraform output -raw "$m" > "openshift/${m}.yaml" 2>/dev/null || rm -f "openshift/${m}.yaml"
done
```

| Output | Contents |
| --- | --- |
| `manifest_oci_ccm` | OCI Cloud Controller Manager (Namespace, SA, ClusterRole, ClusterRoleBinding, DaemonSet) |
| `manifest_oci_csi` | OCI CSI driver resources |
| `manifest_oci_ccm_config` | CCM cloud-provider config Secret |
| `manifest_oci_csi_config` | CSI volume-provisioner config Secret |
| `manifest_machineconfig_ccm` | MachineConfig for CCM provider-id |
| `manifest_machineconfig_csi` | MachineConfig for iscsid service |
| `manifest_machineconfig_device_path` | MachineConfig for consistent device paths |
| `manifest_cluster_network` | Network operator config (internalMasqueradeSubnet) |
| `manifest_machineconfig_eval_user_data` | MachineConfig for OCI eval user-data |
| `manifest_oca` | Oracle Cloud Agent (null when `use_oracle_cloud_agent = false`) |
| `manifest_autoscaler_operator` | Autoscaler operator bootstrap (null when `use_autoscaling_operator = false`) |
| `manifest_autoscaler_runtime_configmap` | Autoscaler runtime manifest ConfigMap (null when `use_autoscaling_operator = false`) |
| `manifest_image_tag_mirror_set` | ImageTagMirrorSet redirecting tag-based pulls to the mirror (null when `private_registry` is unset) |
| `manifest_oci_custom_ca` | ConfigMaps carrying `additional_trust_bundle` into the CCM and CSI namespaces (null when `additional_trust_bundle` is unset) |

### Dynamic Custom Manifest Output
---
The `dynamic_custom_manifest` output contains the required manifests, plus the custom CA ConfigMaps, the ImageTagMirrorSet, and the Oracle Cloud Agent and autoscaler manifests when enabled, concatenated into one multi-document YAML string. It works with the Assisted Installer, with `oc apply -f`, and with the agent-based installer: saved as a single file in `openshift/`, it is split into separate manifests when the ISO is built (verified with `openshift-install` 4.22.18, 28 manifests). This is what Oracle's and Red Hat's documentation describe.

Write it with `terraform output -raw dynamic_custom_manifest > openshift/manifest.yaml`. Without `-raw`, Terraform wraps the value in `<<EOT ... EOT` and the installer fails with `could not decode YAML ... Error reading multiple YAMLs`.

### Autoscaler Manifest Output
---
The OCI OpenShift Autoscaler manifests are generated by the `create-cluster` stack for Day 0 enablement and by the `create-autoscaler-operator` stack for Day 1 enablement. These manifests are emitted through the `autoscaling_manifest` output and include the autoscaler operator bootstrap, runtime resources, configuration, and `OCIClusterAutoscaler` custom resource.

For installation, verification, scale up/down, monitoring, troubleshooting, and cleanup steps, see the [OCI OpenShift Autoscaler Guide](/docs/AUTOSCALER.md).
