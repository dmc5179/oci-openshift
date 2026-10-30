# Running Terraform on a Disconnected Bastion

`terraform init` downloads providers from `registry.terraform.io`. On an
air-gapped bastion that fails immediately:

```
Error: Failed to query available provider packages

Could not retrieve the list of available versions for provider
hashicorp/external: could not connect to registry.terraform.io
```

Two scripts handle this. `scripts/build-offline-bundle.sh` runs on a connected
host and packs everything the bastion needs into one tarball.
`scripts/install-offline-bundle.sh` runs on the bastion, from inside that
tarball, and needs no network.

## Quick path

On a connected host, from a checkout of this repo:

```bash
./scripts/build-offline-bundle.sh
```

This writes `oci-openshift-offline.tgz`, about 100 MB. Carry it to the bastion,
then:

```bash
tar -xzf oci-openshift-offline.tgz
./oci-openshift-offline/oci-openshift/scripts/install-offline-bundle.sh
```

The install script checks the bundle's checksums, installs Terraform, writes
`~/.terraformrc` pointing at the bundled provider mirror, and runs
`terraform init` in every stack. When it finishes, continue with
[disconnected-bastion-setup.md](disconnected-bastion-setup.md), using the stacks
in `oci-openshift-offline/oci-openshift/terraform-stacks/`.

Useful build options:

| Option | Effect |
|---|---|
| `--pin oracle/oci=9.10.0` | Use a specific provider version instead of the newest allowed. Repeatable. |
| `--terraform-version 1.17.0` | Terraform version to bundle (the default). |
| `--openshift-clients` | Also bundle `oc`, `oc-mirror` and `openshift-install-fips` for RHEL 9, about 650 MB more. |
| `--ref REV` | Bundle a specific commit. The default is the working tree. |

Run either script with `--help` for the full list.

## What is in the bundle

```
oci-openshift-offline/
├── BUNDLE-INFO.txt        what was bundled, and the exact versions
├── SHA256SUMS             checksum of every file, checked on the bastion
├── bin/terraform          verified against HashiCorp's SHA256SUMS, already unzipped
├── oci-openshift/         this repo, plus a .terraform.lock.hcl in every stack
├── tf-provider-mirror/    every provider the lock files name
└── openshift-clients/     only with --openshift-clients
```

Some details matter here:

- **The whole repo is included, not just `terraform-stacks/`.**
  `terraform-stacks/shared_modules/manifest/manifests` and
  `.../oci-ccm-csi-drivers` are symlinks into `custom_manifests/`. Copying only
  `terraform-stacks/` leaves them dangling: `init` succeeds but `validate` and
  `plan` fail with `no file exists at ../shared_modules/manifest/manifests/...`.
- **Terraform ships unzipped.** RHEL 9 and UBI 9 do not always have `unzip`, so
  the zip is verified and extracted on the connected host. The original zip and
  HashiCorp's `SHA256SUMS` are kept in `bin/` for provenance.
- **Across all stacks there are exactly three providers:** `oracle/oci` (every
  stack), `hashicorp/time` (every stack except `create-autoscaler-operator`) and
  `hashicorp/external` (`create-cluster`, `add-nodes`). About 80 MB together for
  `linux_amd64`.

## Why the lock files matter

The stacks declare open-ended constraints such as `>= 6.12.0`, and
`.terraform.lock.hcl` is gitignored. Nothing in the repo pins a provider
version: `terraform init` resolves whatever is newest on the day it runs. Two
bundles built a week apart can contain different versions of `oracle/oci`.
`BUNDLE-INFO.txt` records what you got; `--pin` lets you choose.

The lock files do a second job that is easy to miss: **they are the only
integrity check on the provider mirror.** Packages installed from a filesystem
mirror are reported as `(unauthenticated)`. With the lock file present,
Terraform verifies each package against the checksums the registry published,
so a provider package whose contents have been altered is rejected:

```
Error while installing hashicorp/time v0.14.2: the current package for
registry.terraform.io/hashicorp/time 0.14.2 doesn't match any of the
checksums previously recorded in the dependency lock file
```

Without the lock file, the same altered package installs silently and `init`
reports success. If you ever see this error, do not work around it: the
provider on the bastion is not the one resolved on the connected host.

`SHA256SUMS` covers the rest of the bundle, so damage in transfer is caught
before anything is installed.

## What the scripts do

If you cannot use the scripts, these are the steps they perform.

### On the connected host

1. **Resolve and pin providers.** In a clean copy of the repo, run
   `terraform init -backend=false` in every stack. Each stack gets a
   `.terraform.lock.hcl` recording the exact versions chosen and their
   checksums. To pin a version, add a temporary override file declaring
   `version = "= X.Y.Z"` for that provider before running `init`.

2. **Build the mirror.** In every stack, run:

   ```bash
   terraform providers mirror -platform=linux_amd64 /path/to/tf-provider-mirror
   ```

   This downloads the versions the lock file selected. Set `-platform` to the
   bastion's platform, not the host's.

3. **Bundle.** Combine a clean copy of the repo, the lock files (not the
   `.terraform/` directories), the mirror and the Terraform binary.

### On the bastion

4. **Point Terraform at the mirror.** Create `~/.terraformrc`:

   ```hcl
   provider_installation {
     filesystem_mirror {
       path    = "/home/<user>/oci-openshift-offline/tf-provider-mirror"
       include = ["registry.terraform.io/*/*"]
     }
     direct {
       exclude = ["registry.terraform.io/*/*"]
     }
   }
   ```

   Use an absolute path. Both blocks matter: `filesystem_mirror` says where to
   find providers, and `direct { exclude ... }` stops Terraform from ever trying
   the public registry. If a provider is missing from the mirror, you get an
   immediate error naming it rather than a network timeout:

   ```
   Could not retrieve the list of available versions for provider
   hashicorp/external: provider registry.terraform.io/hashicorp/external was not
   found in any of the search locations
   ```

   To keep the config out of your home directory, put it anywhere and export
   `TF_CLI_CONFIG_FILE=/path/to/terraformrc`. The install script's
   `--cli-config` option does this.

5. **Initialize** each stack with a plain `terraform init`. Expected output, for
   `create-cluster`:

   ```
   - Reusing version 9.11.0 of oracle/oci from the dependency lock file
   - Reusing version 2.4.2 of hashicorp/external from the dependency lock file
   - Reusing version 0.14.2 of hashicorp/time from the dependency lock file
   - Installing oracle/oci v9.11.0...
   - Installed oracle/oci v9.11.0 (unauthenticated)
   ...
   Terraform has been successfully initialized!
   ```

   The `Reusing version ... from the dependency lock file` lines confirm the
   lock file was found and the versions are pinned. If they are missing, the
   lock file did not make it across.

For a one-off init without a CLI config, `terraform init -plugin-dir=/path/to/tf-provider-mirror`
also works offline, but has to be repeated for every stack.

## OpenShift clients and FIPS

With `--openshift-clients`, the bundle also gets the RHEL 9 builds of `oc`,
`oc-mirror` and the installer from `mirror.openshift.com`, each verified against
the mirror's `sha256sum.txt`. `--openshift-version` selects the channel or
release; the default is `stable-4.22`.

A cluster with `fips: true` cannot be installed with the plain
`openshift-install`; it needs `openshift-install-fips`, run on a bastion that
is itself in FIPS mode. Red Hat documents extracting it from the release image
with `oc adm release extract --command=openshift-install-fips`, which needs a
pull secret. That is not necessary: `openshift-install-rhel9-amd64.tar.gz` on
the public mirror contains `openshift-install-fips`, and for 4.22.18 it is
byte-identical to the extracted binary. That tarball is the one bundled. The
generic `openshift-install-linux.tar.gz` is not FIPS-capable.

## Updating providers later

Build a new bundle. On the bastion, replace the whole bundle directory, mirror
and lock files together, and run the install script again. It does a plain
`terraform init`, which installs the newly pinned versions.

Do not use `terraform init -upgrade` for this. `-upgrade` ignores the lock file
and picks the newest version the constraint allows from whatever is in the
mirror. With a single version mirrored it lands on the same answer, but if old
and new packages are both present it silently overrides the pin.

## Alternative: the deployer container

[container-deployer.md](../container-deployer.md) describes an image with the
providers already installed in each stack, built on a connected host. If you can
move a container image to the bastion, it sidesteps this procedure. The same
pinning caveat applies: the image contains whatever provider versions were
current when it was built.

## Testing this procedure

`scripts/test-offline-terraform-init.sh` runs the whole workflow. It runs the
build script on this host, then copies only the resulting tarball into a fresh
UBI9 container started with `--network=none`. Inside, it unpacks the tarball,
runs the install script, and checks that every stack initializes with its
providers pinned and validates. It also checks that the `~/.terraformrc` the
install script writes matches the one shown above, and that the workflow fails
safely on a corrupted bundle, a tampered provider and a missing provider.

Run it after changing either script, this doc, any stack's providers, or the
repo layout:

```bash
./scripts/test-offline-terraform-init.sh            # working tree, incl. uncommitted edits
./scripts/test-offline-terraform-init.sh --ref HEAD # a specific commit
```

It needs `podman`, `git`, `curl`, `sha256sum`, `tar` and `python3` on the host,
and network access for the connected-host half. Terraform does not need to be
installed on the host.
