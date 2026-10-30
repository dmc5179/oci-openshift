#!/bin/bash
set -euo pipefail

# Installs a bundle made by scripts/build-offline-bundle.sh on a disconnected
# bastion: checks the bundle's SHA256SUMS, installs terraform (and the
# OpenShift clients, if bundled), points terraform at the bundled provider
# mirror, and runs terraform init in every stack.
#
# Run it from inside the unpacked bundle:
#
#   tar -xzf oci-openshift-offline.tgz
#   ./oci-openshift-offline/oci-openshift/scripts/install-offline-bundle.sh
#
# Nothing here needs network access.
#
# Usage:
#   ./install-offline-bundle.sh [--bin-dir DIR] [--cli-config FILE] [--no-init]
#
#   --bin-dir DIR      Where to install terraform. Default: /usr/local/bin as
#                      root, otherwise ~/.local/bin
#   --cli-config FILE  Where to write the terraform CLI config. Default:
#                      ~/.terraformrc. Anywhere else needs
#                      TF_CLI_CONFIG_FILE set to it.
#   --no-init          Stop after installing; do not run terraform init.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_DIR="$(cd "${REPO_DIR}/.." && pwd)"

if [[ "$(id -u)" -eq 0 ]]; then BIN_DIR="/usr/local/bin"; else BIN_DIR="${HOME}/.local/bin"; fi
CLI_CONFIG="${HOME}/.terraformrc"
INIT=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir)    BIN_DIR="$2"; shift 2 ;;
    --cli-config) CLI_CONFIG="$2"; shift 2 ;;
    --no-init)    INIT=false; shift ;;
    -h|--help)    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "${BUNDLE_DIR}/BUNDLE-INFO.txt" || ! -d "${BUNDLE_DIR}/tf-provider-mirror" ]]; then
  echo "ERROR: ${BUNDLE_DIR} does not look like an offline bundle." >&2
  echo "Run this script from inside a bundle made by build-offline-bundle.sh." >&2
  exit 2
fi

echo "Bundle: ${BUNDLE_DIR}"
sed -n '2,/^OpenShift:/p' "${BUNDLE_DIR}/BUNDLE-INFO.txt" | sed 's/^/  /'

# --- Integrity ---------------------------------------------------------------

echo
echo "[1/4] Checking bundle integrity"
# Catches corruption or truncation in transfer. Provider packages are checked
# again by terraform against the lock files during init.
(cd "$BUNDLE_DIR" && sha256sum -c --quiet SHA256SUMS) \
  || { echo "ERROR: bundle contents do not match SHA256SUMS; do not use this bundle" >&2; exit 1; }
echo "  all files match SHA256SUMS"

# --- Terraform ---------------------------------------------------------------

echo
echo "[2/4] Installing binaries to ${BIN_DIR}"
mkdir -p "$BIN_DIR"
install -m 0755 "${BUNDLE_DIR}/bin/terraform" "${BIN_DIR}/terraform"
TF="${BIN_DIR}/terraform"
echo "  $("$TF" version | head -1)"
# Bundled only with build-offline-bundle.sh --openshift-clients.
OCP_DIR="${BUNDLE_DIR}/openshift-clients"
install_from() {  # install_from GLOB MEMBER...
  local glob="$1" tarball
  tarball="$(compgen -G "$glob" | head -1)" || true
  shift
  if [[ -z "$tarball" ]]; then
    echo "  ERROR: openshift-clients/ is present but has no $(basename "$glob")" >&2
    exit 1
  fi
  tar -xzf "$tarball" -C "$BIN_DIR" "$@"
  for m in "$@"; do chmod 0755 "${BIN_DIR}/${m}"; echo "  ${m}"; done
}
if [[ -d "$OCP_DIR" ]]; then
  install_from "${OCP_DIR}/openshift-client-linux-*-rhel9.tar.gz" oc kubectl
  install_from "${OCP_DIR}/oc-mirror.rhel9.tar.gz"                 oc-mirror
  install_from "${OCP_DIR}/openshift-install-rhel9-*.tar.gz"       openshift-install-fips
fi
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "  NOTE: ${BIN_DIR} is not on PATH. Add it with: export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac

# --- CLI config --------------------------------------------------------------

echo
echo "[3/4] Writing ${CLI_CONFIG}"
# Keep this block identical to the one in docs/terraform-offline-init.md;
# scripts/test-offline-terraform-init.sh checks that they match.
NEW_CONFIG="$(cat <<EOF
provider_installation {
  filesystem_mirror {
    path    = "${BUNDLE_DIR}/tf-provider-mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF
)"
if [[ -f "$CLI_CONFIG" ]] && [[ "$(cat "$CLI_CONFIG")" != "$NEW_CONFIG" ]]; then
  backup="${CLI_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CLI_CONFIG" "$backup"
  echo "  existing config backed up to ${backup}"
fi
mkdir -p "$(dirname "$CLI_CONFIG")"
printf '%s\n' "$NEW_CONFIG" > "$CLI_CONFIG"
sed 's/^/  /' "$CLI_CONFIG"
if [[ "$CLI_CONFIG" != "${HOME}/.terraformrc" ]]; then
  echo "  NOTE: set TF_CLI_CONFIG_FILE=${CLI_CONFIG} before running terraform"
  export TF_CLI_CONFIG_FILE="$CLI_CONFIG"
fi

# --- Init --------------------------------------------------------------------

echo
if [[ "$INIT" != true ]]; then
  echo "[4/4] terraform init: skipped (--no-init)"
  exit 0
fi

echo "[4/4] terraform init in every stack"
FAILED=0
for lock in "${REPO_DIR}"/terraform-stacks/*/.terraform.lock.hcl; do
  dir="$(dirname "$lock")"; s="$(basename "$dir")"
  if out="$("$TF" -chdir="$dir" init -input=false -no-color 2>&1)"; then
    want="$(grep -c '^provider ' "$lock")"
    got="$(grep -c 'Reusing version .* from the dependency lock file' <<<"$out" || true)"
    echo "  ok    ${s}  (${got}/${want} providers pinned by the lock file)"
  else
    echo "  FAIL  ${s}"
    sed 's/^/        /' <<<"$out" | tail -15
    FAILED=$((FAILED + 1))
  fi
done

echo
if [[ "$FAILED" -ne 0 ]]; then
  echo "${FAILED} stack(s) failed to initialize." >&2
  exit 1
fi
echo "Ready. The stacks are in ${REPO_DIR}/terraform-stacks/"
echo "Continue with ${REPO_DIR}/docs/disconnected-bastion-setup.md"
