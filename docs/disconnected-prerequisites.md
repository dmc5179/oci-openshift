# What to Bring into a Disconnected Enclave

Everything that must exist inside an air-gapped environment before deploying
OpenShift on OCI with the Agent-based Installer and this repo's terraform. Each
item links to where it is covered in detail.

## Checklist

| Item | How it gets there | Details |
|---|---|---|
| Terraform, providers and this repo | `scripts/build-offline-bundle.sh` | [terraform-offline-init.md](terraform-offline-init.md) |
| `oc`, `oc-mirror`, `openshift-install-fips` | Same bundle, with `--openshift-clients` | [terraform-offline-init.md](terraform-offline-init.md#openshift-clients-and-fips) |
| A mirror registry | Installed inside the enclave | [Mirror registry](#mirror-registry) |
| OpenShift release images | `oc-mirror` | [imageset-config.yaml](imageset-config.yaml) |
| OCI CCM/CSI, autoscaler and troubleshooting images | `oc-mirror`, same run | [imageset-config.yaml](imageset-config.yaml) |
| Operator catalogs you need | `oc-mirror`, same run | [Operator catalogs](#operator-catalogs) |
| Registry CA and merged pull secret | Prepared by you | [Certificates and credentials](#certificates-and-credentials) |
| OCI region metadata (non-commercial realms) | Prepared by you | [OCI realm settings](#oci-realm-settings) |
| Resource attribution tags in the tenancy | `create-resource-attribution-tags` stack | [OCI prerequisites](#oci-prerequisites) |

Nothing else needs to be carried in by hand. In particular:

- **No web server is needed for the rootfs.** With
  `is_disconnected_installation = true`, the create-cluster stack uploads the
  rootfs and the agent ISO to Object Storage, creates pre-authenticated
  requests for them, and sets `bootArtifactsBaseURL` in `agent-config.yaml` to
  the rootfs PAR. See [disconnected-bastion-setup.md](disconnected-bastion-setup.md).
- **No manifest needs hand-editing to point at the mirror.** With
  `private_registry` set, the stack adds `imageDigestSources` to
  `install-config.yaml` for the release and generates an `ImageTagMirrorSet`
  redirecting every other image. Write the `manifest_image_tag_mirror_set`
  output into `openshift/` before creating the ISO;
  `scripts/generate-ocp-artifacts.sh` does this.
- **No separate RHCOS download is needed.** The agent ISO is built from the
  release payload, so it comes from the mirrored release images.

## Mirror registry

Any registry that speaks the Docker v2 API works: the mirror registry for Red
Hat OpenShift (a single-binary install), Red Hat Quay, Harbor, Nexus. It must be
running and reachable from both the bastion and the cluster's subnets before
you mirror into it, and it needs:

- a TLS certificate that the cluster nodes can be made to trust (see below);
- credentials to push and pull.

**Set `private_registry` to exactly the destination you give `oc-mirror`,**
without `docker://`. The stack builds its mirror redirects from that value and
assumes `oc-mirror`'s layout beneath it. If they differ, every redirect points
at a path that does not exist. [imageset-config.yaml](imageset-config.yaml)
shows the layout.

## Operator catalogs

`imageset-config.yaml` mirrors the Red Hat operator index with only the
packages it lists. Add the operators you plan to install, such as OpenShift
Data Foundation or logging, under `packages:`. Certified and community catalogs
are separate indexes (`certified-operator-index`, `community-operator-index`),
mirrored the same way if you need them.

`oc-mirror` writes a `CatalogSource` for each mirrored catalog into its
workspace's `cluster-resources` directory. Apply those after install.

## Certificates and credentials

| Item | Used for |
|---|---|
| Red Hat pull secret | Pulling from Red Hat registries while mirroring, on the connected side |
| Merged pull secret | The Red Hat pull secret plus your mirror registry's credentials. Set as `redhat_pull_secret`. |
| Mirror registry CA | Set as `additional_trust_bundle`. The stack adds it to `install-config.yaml` with `additionalTrustBundlePolicy: Always`, so every node trusts the registry. |
| SSH key pair | `public_ssh_key`, for node access |
| OCI API credentials | Terraform and the OCI CLI on the bastion: an API key, or instance principals |

### Realms with their own certificate authority

In some non-commercial realms the OCI API endpoints present certificates from a
CA that is not in the public trust set. Three things then need that CA:

1. **Terraform's OCI provider** reads it from `OCI_DEFAULT_CERTS_PATH`:

   ```bash
   export OCI_DEFAULT_CERTS_PATH=/path/to/realm-ca-bundle.pem
   ```

2. **The OCI CLI** does not read that variable. It uses `OCI_CLI_CERT_BUNDLE`,
   or the `--cert-bundle` option:

   ```bash
   export OCI_CLI_CERT_BUNDLE=/path/to/realm-ca-bundle.pem
   ```

3. **The cluster's cloud controller manager and CSI driver.** They verify the
   OCI API using their own image's trust store, which the node trust store
   does not reach. Include the realm CA in `additional_trust_bundle`; the stack
   then mounts it into those pods as well. Without it, the CCM cannot
   authenticate, nodes keep their `uninitialized` taint, and the install never
   converges.

## OCI realm settings

For a realm or region the SDKs do not know about, the OCI CLI needs
`~/.oci/regions-config.json` describing it, and the cluster drivers need the
same information as region metadata. The create-cluster stack reads it from the
bastion's instance metadata and passes it to the CCM and CSI driver. For realms
that construct service endpoints differently from commercial OCI, also set
`enable_realm_specific_endpoints = true`. [oc6-quickstart.md](oc6-quickstart.md)
walks through an isolated-realm deployment.

## OCI prerequisites

The create-cluster stack creates the VCN, subnets, gateways, load balancers,
DNS zone, IAM dynamic group and policies, Object Storage bucket, PARs, custom
image and instances. Before running it you need:

- a compartment for the cluster;
- the resource attribution tags, from the `create-resource-attribution-tags`
  stack, created once per tenancy;
- permission to create all of the above in that compartment.
