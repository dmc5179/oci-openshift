#!/bin/bash
set -euo pipefail

# Builds a self-contained bundle for running this repo's terraform stacks on a
# disconnected (air-gapped) bastion. Run it on a connected host, carry the
# resulting tarball across, and run scripts/install-offline-bundle.sh from
# inside it on the bastion.
#
# The bundle contains:
#   bin/terraform          Terraform, verified against HashiCorp's SHA256SUMS
#                          and already unzipped (RHEL/UBI 9 may lack unzip)
#   oci-openshift/         This repo at the chosen commit, plus a
#                          .terraform.lock.hcl in every stack pinning the exact
#                          provider versions and their checksums
#   tf-provider-mirror/    Every provider those lock files name, for the
#                          bastion's platform
#   openshift-clients/     Optional: oc, oc-mirror and the FIPS-capable
#                          installer, RHEL 9 builds, verified against the
#                          mirror's sha256sum.txt
#   SHA256SUMS             Checksum of every file above, checked on the bastion
#
# See docs/terraform-offline-init.md for why each piece is needed.
#
# Usage:
#   ./build-offline-bundle.sh [options]
#
#   --output DIR               Where to write the bundle. Default: ./oci-openshift-offline
#   --ref REV                  Commit to bundle. Default: the working tree,
#                              including uncommitted changes to tracked files.
#   --terraform-version VER    Default: 1.17.0
#   --platform PLAT            Bastion platform. Default: linux_amd64
#   --pin NS/NAME=VER          Pin a provider instead of taking the newest that
#                              satisfies the stacks' constraints. Repeatable, e.g.
#                              --pin oracle/oci=9.10.0
#   --openshift-clients        Also bundle the OpenShift clients.
#   --openshift-version VER    Client channel or exact release. Default: stable-4.22
#   --no-tarball               Leave the bundle as a directory only.
#
# Requires git, curl, sha256sum, tar and python3. Terraform does not need to be
# installed on this host: the bundle's own copy is used.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT="./oci-openshift-offline"
REF=""
TERRAFORM_VERSION="1.17.0"
PLATFORM="linux_amd64"
PINS=()
OPENSHIFT_CLIENTS=false
OPENSHIFT_VERSION="stable-4.22"
TARBALL=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)            OUTPUT="$2"; shift 2 ;;
    --ref)               REF="$2"; shift 2 ;;
    --terraform-version) TERRAFORM_VERSION="$2"; shift 2 ;;
    --platform)          PLATFORM="$2"; shift 2 ;;
    --pin)               PINS+=("$2"); shift 2 ;;
    --openshift-clients) OPENSHIFT_CLIENTS=true; shift ;;
    --openshift-version) OPENSHIFT_VERSION="$2"; shift 2 ;;
    --no-tarball)        TARBALL=false; shift ;;
    -h|--help)           sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                   echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

for cmd in git curl sha256sum tar python3; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found in PATH" >&2; exit 2; }
done
for p in "${PINS[@]}"; do
  [[ "$p" =~ ^[a-z0-9-]+/[a-z0-9-]+=[0-9][0-9A-Za-z.+-]*$ ]] \
    || { echo "ERROR: --pin must look like namespace/name=version, got: $p" >&2; exit 2; }
done
case "$PLATFORM" in
  linux_amd64) RHEL_ARCH=amd64 ;;
  linux_arm64) RHEL_ARCH=arm64 ;;
  *) echo "ERROR: unsupported platform: $PLATFORM" >&2; exit 2 ;;
esac

if [[ -e "$OUTPUT" ]]; then
  echo "ERROR: ${OUTPUT} already exists; remove it or pick another --output" >&2
  exit 2
fi
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
BUILD="$(mktemp -d -t oci-openshift-bundle.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

unzip_to() {  # unzip_to ZIP DIR, without depending on unzip being installed
  python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
}

cd "$REPO_DIR"
if [[ -z "$REF" ]]; then
  # 'git stash create' commits the working tree without touching it, so
  # uncommitted edits are bundled too. It prints nothing when the tree is
  # clean. Untracked files are not included.
  REF="$(git stash create)"
  REF="${REF:-HEAD}"
  SOURCE_DESC="$(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo ' + uncommitted changes')"
  # New files are left out until they are at least staged. Say so, rather than
  # silently shipping a bundle that lacks them. They are deliberately not
  # swept in automatically: an untracked file is as likely to be a tfvars or
  # a pull secret as a new script.
  UNTRACKED="$(git ls-files --others --exclude-standard)"
  if [[ -n "$UNTRACKED" ]]; then
    echo "WARNING: these untracked files are NOT in the bundle (git add them to include):" >&2
    sed 's/^/  /' <<<"$UNTRACKED" >&2
  fi
else
  SOURCE_DESC="$(git rev-parse --short "$REF")"
fi

echo "Bundle:     ${OUTPUT}"
echo "Source:     ${SOURCE_DESC}"
echo "Terraform:  ${TERRAFORM_VERSION} (${PLATFORM})"
[[ ${#PINS[@]} -gt 0 ]] && echo "Pins:       ${PINS[*]}"

# --- Terraform ---------------------------------------------------------------

echo
echo "[1/4] Terraform ${TERRAFORM_VERSION}"
TF_BASE="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
TF_ZIP="terraform_${TERRAFORM_VERSION}_${PLATFORM}.zip"
TF_SUMS="terraform_${TERRAFORM_VERSION}_SHA256SUMS"
mkdir -p "${OUTPUT}/bin" "${BUILD}/tf"
curl -fsSL -o "${BUILD}/tf/${TF_ZIP}"  "${TF_BASE}/${TF_ZIP}"
curl -fsSL -o "${BUILD}/tf/${TF_SUMS}" "${TF_BASE}/${TF_SUMS}"
# A checksum mismatch is fatal. Never ship a binary that failed it.
(cd "${BUILD}/tf" && grep " ${TF_ZIP}\$" "$TF_SUMS" | sha256sum -c --quiet -) \
  || { echo "ERROR: ${TF_ZIP} does not match HashiCorp's published SHA256SUMS" >&2; exit 1; }
echo "  checksum verified against ${TF_SUMS}"
unzip_to "${BUILD}/tf/${TF_ZIP}" "${OUTPUT}/bin"
chmod 0755 "${OUTPUT}/bin/terraform"
cp "${BUILD}/tf/${TF_ZIP}" "${BUILD}/tf/${TF_SUMS}" "${OUTPUT}/bin/"

# The host may not be the bastion's platform. Use the bundled binary only if it
# runs here; otherwise fall back to a host terraform for resolving providers.
if "${OUTPUT}/bin/terraform" version >/dev/null 2>&1; then
  TF="${OUTPUT}/bin/terraform"
elif command -v terraform >/dev/null; then
  TF="$(command -v terraform)"
  echo "  bundled binary does not run on this host; resolving providers with ${TF}"
else
  echo "ERROR: the bundled terraform does not run on this host and none is installed" >&2
  exit 1
fi

# --- Repo and lock files -----------------------------------------------------

echo
echo "[2/4] Repo and provider lock files"
mkdir -p "${OUTPUT}/oci-openshift" "${BUILD}/resolve"
git archive "$REF" | tar -x -C "${OUTPUT}/oci-openshift"
git archive "$REF" | tar -x -C "${BUILD}/resolve"

# Every directory under terraform-stacks/ with .tf files, except the shared
# modules. Discovered, so a new stack is bundled without editing this script.
mapfile -t STACKS < <(
  cd "${BUILD}/resolve/terraform-stacks" &&
  for d in */; do
    d="${d%/}"
    [[ "$d" == shared_modules ]] && continue
    compgen -G "${d}/*.tf" >/dev/null && echo "$d"
  done
)
echo "  stacks: ${STACKS[*]}"

# Keep this host's own terraform config and plugin cache out of it, so
# providers come from the registry and the lock files record full checksums.
: > "${BUILD}/empty-terraformrc"
export TF_CLI_CONFIG_FILE="${BUILD}/empty-terraformrc"
unset TF_PLUGIN_CACHE_DIR TF_DATA_DIR

tf_init() {  # tf_init STACK LOG
  "$TF" -chdir="${BUILD}/resolve/terraform-stacks/$1" init -backend=false -input=false -no-color > "$2" 2>&1 \
    || { echo "ERROR: terraform init failed for $1:" >&2; tail -20 "$2" >&2; exit 1; }
}

for s in "${STACKS[@]}"; do
  tf_init "$s" "${BUILD}/init-${s}.log"
done

# A pin is applied with a temporary override file, and only in stacks whose
# lock file shows they use that provider, so no stack gains a dependency it
# does not have. The override exists only in this resolve copy; the bundle
# gets the resulting lock file, which is all the bastion needs.
if [[ ${#PINS[@]} -gt 0 ]]; then
  for s in "${STACKS[@]}"; do
    dir="${BUILD}/resolve/terraform-stacks/${s}"
    override=""
    for p in "${PINS[@]}"; do
      src="${p%%=*}"; ver="${p#*=}"; name="${src#*/}"
      grep -q "^provider \"registry.terraform.io/${src}\"" "${dir}/.terraform.lock.hcl" || continue
      override+="    ${name} = { source = \"${src}\", version = \"= ${ver}\" }"$'\n'
    done
    [[ -z "$override" ]] && continue
    printf 'terraform {\n  required_providers {\n%s  }\n}\n' "$override" > "${dir}/zz_offline_bundle_pin_override.tf"
    rm -rf "${dir}/.terraform" "${dir}/.terraform.lock.hcl"
    tf_init "$s" "${BUILD}/init-pinned-${s}.log"
  done
  for p in "${PINS[@]}"; do
    src="${p%%=*}"; ver="${p#*=}"
    grep -l "^provider \"registry.terraform.io/${src}\"" "${BUILD}"/resolve/terraform-stacks/*/.terraform.lock.hcl >/dev/null 2>&1 \
      || echo "  WARNING: no stack uses ${src}; --pin ${p} had no effect"
  done
fi

for s in "${STACKS[@]}"; do
  cp "${BUILD}/resolve/terraform-stacks/${s}/.terraform.lock.hcl" "${OUTPUT}/oci-openshift/terraform-stacks/${s}/"
done

# --- Provider mirror ---------------------------------------------------------

echo
echo "[3/4] Provider mirror (${PLATFORM})"
for s in "${STACKS[@]}"; do
  "$TF" -chdir="${BUILD}/resolve/terraform-stacks/${s}" \
    providers mirror -platform="$PLATFORM" "${OUTPUT}/tf-provider-mirror" > "${BUILD}/mirror-${s}.log" 2>&1 \
    || { echo "ERROR: providers mirror failed for ${s}:" >&2; tail -20 "${BUILD}/mirror-${s}.log" >&2; exit 1; }
done
unset TF_CLI_CONFIG_FILE

PROVIDERS="$(cd "${OUTPUT}/oci-openshift/terraform-stacks" &&
  grep -h -A1 '^provider' */.terraform.lock.hcl | grep -E 'provider|version' | paste - - | sort -u \
    | sed -E 's/provider "registry.terraform.io\/([^"]+)".*version += "([^"]+)"/\1 \2/')"
sed 's/^/  /' <<<"$PROVIDERS"

# --- OpenShift clients -------------------------------------------------------

echo
if [[ "$OPENSHIFT_CLIENTS" == true ]]; then
  echo "[4/4] OpenShift clients (${OPENSHIFT_VERSION})"
  OCP_BASE="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_VERSION}"
  OCP_DIR="${OUTPUT}/openshift-clients"
  mkdir -p "$OCP_DIR"
  curl -fsSL -o "${OCP_DIR}/release.txt"   "${OCP_BASE}/release.txt"
  curl -fsSL -o "${OCP_DIR}/sha256sum.txt" "${OCP_BASE}/sha256sum.txt"
  OCP_RELEASE="$(awk '/^Name:/ {print $2}' "${OCP_DIR}/release.txt")"
  echo "  release: ${OCP_RELEASE}"
  # RHEL 9 builds, matching the bastion this bundle is for. The RHEL 9
  # installer tarball contains openshift-install-fips, byte-identical to what
  # 'oc adm release extract --command=openshift-install-fips' produces, so no
  # pull secret is needed. The generic openshift-install-linux.tar.gz cannot
  # install a cluster with fips: true.
  for f in "openshift-client-linux-${RHEL_ARCH}-rhel9.tar.gz" \
           "oc-mirror.rhel9.tar.gz" \
           "openshift-install-rhel9-${RHEL_ARCH}.tar.gz"; do
    grep -q " ${f}\$" "${OCP_DIR}/sha256sum.txt" \
      || { echo "ERROR: ${f} is not listed in ${OCP_BASE}/sha256sum.txt" >&2; exit 1; }
    curl -fsSL -o "${OCP_DIR}/${f}" "${OCP_BASE}/${f}"
    (cd "$OCP_DIR" && grep " ${f}\$" sha256sum.txt | sha256sum -c --quiet -) \
      || { echo "ERROR: ${f} does not match the mirror's sha256sum.txt" >&2; exit 1; }
    echo "  ${f}: checksum verified"
  done

else
  echo "[4/4] OpenShift clients: skipped (use --openshift-clients)"
fi

# --- Manifest and tarball ----------------------------------------------------

cat > "${OUTPUT}/BUNDLE-INFO.txt" <<EOF
oci-openshift offline bundle
Built:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
Source:     ${SOURCE_DESC}
Platform:   ${PLATFORM}
Terraform:  ${TERRAFORM_VERSION}
Providers:
$(sed 's/^/  /' <<<"$PROVIDERS")
OpenShift:  $([[ "$OPENSHIFT_CLIENTS" == true ]] && echo "${OCP_RELEASE} (oc, oc-mirror, openshift-install-fips; RHEL 9)" || echo "not included")

On the bastion:
$([[ "$TARBALL" == true ]] && echo "  tar -xzf $(basename "$OUTPUT").tgz")
  ./$(basename "$OUTPUT")/oci-openshift/scripts/install-offline-bundle.sh
EOF

(cd "$OUTPUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

if [[ "$TARBALL" == true ]]; then
  tar -czf "${OUTPUT}.tgz" -C "$(dirname "$OUTPUT")" "$(basename "$OUTPUT")"
  echo
  echo "Wrote ${OUTPUT}.tgz ($(du -h "${OUTPUT}.tgz" | cut -f1))"
else
  echo
  echo "Wrote ${OUTPUT}/ ($(du -sh "$OUTPUT" | cut -f1))"
fi
echo
cat "${OUTPUT}/BUNDLE-INFO.txt"
