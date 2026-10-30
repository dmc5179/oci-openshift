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

Two scripts check, from a connected host, that all of this can actually be
fetched. Run them before you plan a transfer, and again after changing the
imageset, the stacks' providers, or the image versions in the manifests:

| Script | Proves |
|---|---|
| `scripts/test-offline-terraform-init.sh` | Terraform, the providers, the repo and (with `--openshift-clients`) the OpenShift clients can be bundled, then installed and initialized in a UBI9 container with no network |
| `scripts/test-mirror-images.sh --authfile <pull-secret>` | Every image in `imageset-config.yaml` can be pulled with `oc-mirror`, and lands at the path the create-cluster stack will redirect the cluster to |

`test-mirror-images.sh` mirrors the additional images for real into a
throwaway local registry, because an `oc-mirror --dry-run` reports success even
for a tag that does not exist. The release payload is resolved but not
downloaded unless you pass `--full`.

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

The OCI SDKs know the commercial and government realms they shipped with. For
a realm or region newer than the SDK, every OCI client on the bastion has to be
told about it. That means the OCI CLI and Terraform's OCI provider; the cluster
is handled separately, below.

Each region is described by four values:

| Key | Example | Meaning |
|---|---|---|
| `realmKey` | `oc99` | The realm's identifier |
| `realmDomainComponent` | `example-realm.com` | The domain that service endpoints are built on |
| `regionKey` | `ABC` | The region's short key |
| `regionIdentifier` | `us-example-1` | The region name you use as `region` |

An OCI instance can report its own values:

```bash
curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/regionInfo
```

Give them to the clients in either of two ways. Both the Go SDK (Terraform's
provider) and the Python SDK (the OCI CLI) read both.

**`~/.oci/regions-config.json`**, a JSON *array*, one entry per region:

```json
[
  {
    "realmKey": "oc99",
    "realmDomainComponent": "example-realm.com",
    "regionKey": "ABC",
    "regionIdentifier": "us-example-1"
  }
]
```

**`OCI_REGION_METADATA`**, a single JSON *object* for one region:

```bash
export OCI_REGION_METADATA='{"realmKey":"oc99","realmDomainComponent":"example-realm.com","regionKey":"ABC","regionIdentifier":"us-example-1"}'
```

Note the shape difference: the file holds a list and the variable holds one
object. Terraform's provider (the Go SDK) accepts only those shapes; the OCI
CLI is more lenient with the file. Use the shapes shown and both work.

Related settings, all read by the Go SDK:

| Variable | Purpose |
|---|---|
| `OCI_DEFAULT_REALM` | Domain to assume for a region the SDK cannot place in any realm |
| `OCI_REALM_SPECIFIC_SERVICE_ENDPOINT_TEMPLATE_ENABLED` | Build service endpoints with the realm-specific templates some realms require |
| `OCI_SDK_AUTH_CLIENT_REGION_URL` | Identity endpoint for instance principal authentication in a custom realm |
| `OCI_DEFAULT_CERTS_PATH` | CA bundle for API endpoints with a private CA (the OCI CLI uses `OCI_CLI_CERT_BUNDLE` instead; see above) |

**The cluster.** The CCM and CSI driver need the same region metadata. The
create-cluster stack reads it from the bastion's instance metadata, using the
request shown above, and passes it to both drivers as `OCI_REGION_METADATA`.
For realms that build service endpoints differently from commercial OCI, also
set `enable_realm_specific_endpoints = true`, which sets
`OCI_REALM_SPECIFIC_SERVICE_ENDPOINT_TEMPLATE_ENABLED` on both drivers.
[oc6-quickstart.md](oc6-quickstart.md) walks through an isolated-realm
deployment.

## OCI prerequisites

The create-cluster stack creates the VCN, subnets, gateways, load balancers,
DNS zone, IAM dynamic group and policies, Object Storage bucket, PARs, custom
image and instances. Before running it you need:

- a compartment for the cluster;
- the resource attribution tags, from the `create-resource-attribution-tags`
  stack, created once per tenancy;
- permission to create all of the above in that compartment.
