# Initializing Terraform on a Disconnected Bastion

`terraform init` downloads providers from `registry.terraform.io`. On an
air-gapped bastion that fails immediately:

```
Error: Failed to query available provider packages

Could not retrieve the list of available versions for provider
hashicorp/external: could not connect to registry.terraform.io
```

The fix is to build a local provider mirror on a connected host, carry it to the
bastion together with the dependency lock files, and point Terraform at the
mirror. Every command below was run end to end, with the bastion side executed
inside a network namespace that had no network access at all.

## What gets mirrored

Across all five stacks the repo needs exactly three providers:

| Provider | Used by |
|---|---|
| `oracle/oci` | every stack |
| `hashicorp/time` | every stack except `create-autoscaler-operator` |
| `hashicorp/external` | `create-cluster`, `add-nodes` |

All three together are roughly 80 MB for `linux_amd64`.

## Why the lock files matter

The stacks declare open-ended constraints such as `>= 6.12.0`, and
`.terraform.lock.hcl` is gitignored. Nothing in the repo pins a provider
version: `terraform init` resolves whatever is newest on the day it runs. Two
mirrors built a week apart can contain different versions of `oracle/oci`.

The lock files written on the connected host fix that, and they do a second job
that is easy to miss: **they are the only integrity check on the mirror.**
Packages installed from a filesystem mirror are reported as `(unauthenticated)`.
With the lock file present, Terraform verifies each package against the
checksums the registry published, so a provider package whose contents have
been altered is rejected:

```
Error while installing hashicorp/time v0.14.2: the current package for
registry.terraform.io/hashicorp/time 0.14.2 doesn't match any of the
checksums previously recorded in the dependency lock file
```

Without the lock file, the same altered package installs silently and `init`
reports success. Always carry the lock files across with the mirror.

## On the connected host

You need the same checkout of this repo that you will use on the bastion, and
the same Terraform version.

### 1. Resolve and pin provider versions

Initialize each stack once. This writes a `.terraform.lock.hcl` into each stack
directory recording the exact versions chosen and their checksums.

```bash
cd oci-openshift-mine/terraform-stacks

STACKS="create-resource-attribution-tags create-instance-role-tags create-cluster add-nodes create-autoscaler-operator"

for s in $STACKS; do
  terraform -chdir="$s" init -backend=false -input=false
done
```

`-backend=false` skips backend setup, which is not needed just to resolve
providers.

Record which versions you got. You will want them when reporting a problem, and
they are what you are deploying with:

```bash
grep -h -A1 '^provider' */.terraform.lock.hcl | grep -E 'provider|version' | paste - - | sort -u \
  | sed -E 's/provider "registry.terraform.io\/([^"]+)".*version += "([^"]+)"/\1 \2/'
```

which prints, for example:

```
hashicorp/external 2.4.2
hashicorp/time 0.14.2
oracle/oci 9.11.0
```

### 2. Build the mirror

`terraform providers mirror` downloads the versions selected in each stack's
lock file. Run it in every stack against the same target directory; providers
already present are skipped.

```bash
for s in $STACKS; do
  terraform -chdir="$s" providers mirror -platform=linux_amd64 "$HOME/tf-provider-mirror"
done
```

Set `-platform` explicitly to the bastion's platform. Without it, the mirror
contains packages for whatever machine you ran it on, which is wrong if you built
it on a Mac.

The result:

```
tf-provider-mirror/registry.terraform.io/
├── hashicorp/external/terraform-provider-external_<ver>_linux_amd64.zip
├── hashicorp/time/terraform-provider-time_<ver>_linux_amd64.zip
└── oracle/oci/terraform-provider-oci_<ver>_linux_amd64.zip
```

(plus small `index.json` and `<ver>.json` files, which are harmless).

### 3. Bundle everything for transfer

Take the **whole repo**, not only `terraform-stacks/`.
`terraform-stacks/shared_modules/manifest/manifests` and
`.../oci-ccm-csi-drivers` are symlinks into `custom_manifests/`. Copying only
`terraform-stacks/` leaves them dangling, and `init` succeeds but `validate` and
`plan` fail with `no file exists at ../shared_modules/manifest/manifests/...`.

```bash
cd ../..   # back to the repo root's parent
tar -czf tf-offline-bundle.tgz \
  oci-openshift-mine \
  -C "$HOME" tf-provider-mirror
```

The lock files are inside each stack directory, so they travel with the repo.
Make sure your transfer method does not drop dotfiles.

If Terraform itself is not yet installed on the bastion, also carry the binary:
download the `linux_amd64` zip for the same version from
`https://releases.hashicorp.com/terraform/` and verify it against the published
`SHA256SUMS` before moving it.

## On the bastion

### 4. Unpack

```bash
tar -xzf tf-offline-bundle.tgz -C "$HOME"
```

This gives you `~/oci-openshift-mine` and `~/tf-provider-mirror`.

### 5. Point Terraform at the mirror

Create `~/.terraformrc`:

```hcl
provider_installation {
  filesystem_mirror {
    path    = "/home/<user>/tf-provider-mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
```

Use an absolute path. Both blocks matter. `filesystem_mirror` says where to
find providers, and `direct { exclude ... }` stops Terraform from ever trying
the public registry. If a provider is missing from the mirror, you get an
immediate, explicit error naming it rather than a network timeout:

```
Could not retrieve the list of available versions for provider
hashicorp/external: provider registry.terraform.io/hashicorp/external was not
found in any of the search locations
```

To keep the config out of your home directory, put it anywhere and export
`TF_CLI_CONFIG_FILE=/path/to/terraformrc` instead.

### 6. Initialize

Now `terraform init` works as normal, in each stack you intend to use:

```bash
cd ~/oci-openshift-mine/terraform-stacks/create-cluster
terraform init
```

Expected output, for `create-cluster`:

```
- Reusing version 9.11.0 of oracle/oci from the dependency lock file
- Reusing version 2.4.2 of hashicorp/external from the dependency lock file
- Reusing version 0.14.2 of hashicorp/time from the dependency lock file
- Installing oracle/oci v9.11.0...
- Installed oracle/oci v9.11.0 (unauthenticated)
...
Terraform has been successfully initialized!
```

The `Reusing version ... from the dependency lock file` lines confirm the lock
file was found and the versions are pinned. If they are missing, the lock file
did not make it across.

`(unauthenticated)` is expected for a filesystem mirror; the lock file checksum
check described above is what protects you. If `init` instead reports that a
package `doesn't match any of the checksums previously recorded in the
dependency lock file`, do not work around it. The provider package on the
bastion is not the one that was resolved on the connected host.

Confirm the stack is usable:

```bash
terraform validate
```

From here, continue with the normal workflow in
[disconnected-bastion-setup.md](disconnected-bastion-setup.md).

## Alternative: `-plugin-dir` for a one-off init

Without creating `~/.terraformrc`, you can point a single `init` at the mirror:

```bash
terraform init -plugin-dir="$HOME/tf-provider-mirror"
```

This disables all other install sources for that run, so it is equally safe
offline. It has to be repeated on every `init` in every stack, which is why the
CLI config above is the recommended route.

## Alternative: the deployer container

[container-deployer.md](../container-deployer.md) describes an image with the
providers already installed in each stack, built on a connected host. If you can
move a container image to the bastion, it sidesteps this procedure. The same
pinning caveat applies: the image contains whatever provider versions were
current when it was built.

## Updating providers later

On the connected host, delete the lock files and run steps 1–3 again. Without
deleting them, `init` keeps the versions already pinned.

On the bastion, replace **both** the mirror directory and the lock files, then
run a plain `terraform init` in each stack. Terraform sees the lock file now
pins a different version and installs it from the mirror.

Do not use `terraform init -upgrade` for this. `-upgrade` ignores the lock
file and picks the newest version the constraint allows from whatever is in the
mirror. With a single version mirrored it lands on the same answer, but if old
and new packages are both present it silently overrides the pin.

## Testing this procedure

`scripts/test-offline-terraform-init.sh` runs everything above automatically.
It builds the mirror on this host, then carries the repo, lock files, mirror and
Terraform binary into a fresh UBI9 container started with `--network=none`, with
nothing mounted, and checks that every stack initializes and validates offline.
It also checks that a tampered provider and a missing provider both fail
cleanly.

The `.terraformrc` it uses is extracted from this file, so the test covers what
the doc actually tells people to type. Run it after changing this doc, any
stack's providers, or the repo layout:

```bash
./scripts/test-offline-terraform-init.sh            # working tree, incl. uncommitted edits
./scripts/test-offline-terraform-init.sh --ref HEAD # a specific commit
```

It needs `podman`, `git`, `terraform` and `python3` on the host, and network
access for the connected-host half. A full run takes under a minute.
