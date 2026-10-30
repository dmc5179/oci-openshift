#!/bin/bash
set -euo pipefail

# End-to-end test of the disconnected terraform workflow, in a UBI9 container
# that has no network at all.
#
# Phase 1, on this host and online, plays the connected host: it runs
# scripts/build-offline-bundle.sh exactly as a user would, which downloads and
# verifies terraform, resolves and pins providers, builds the provider mirror
# and packs everything into one tarball.
#
# Phase 2 plays the bastion: a fresh UBI9 container started with
# --network=none. Only the tarball is copied in. Inside, it is unpacked and
# scripts/install-offline-bundle.sh is run from it, then every stack must
# initialize with all providers pinned by the lock files, and validate.
#
# It also checks that the workflow fails safely: a corrupted bundle is refused,
# a provider package altered after the lock file was written is rejected, and a
# provider missing from the mirror is reported by name rather than timing out.
# And it checks that the .terraformrc the install script writes matches the one
# docs/terraform-offline-init.md shows, so the doc cannot drift from the code.
#
# Usage:
#   ./test-offline-terraform-init.sh [--ref REV] [--pin NS/NAME=VER]...
#                                    [--terraform-version VER] [--openshift-clients]
#                                    [--image IMAGE] [--skip-negative] [--keep]
#
#   --ref REV                Test a specific commit. Default: the working tree,
#                            including uncommitted changes to tracked files.
#   --pin, --terraform-version, --openshift-clients
#                            Passed through to build-offline-bundle.sh. With
#                            --openshift-clients, also checks that oc,
#                            oc-mirror and openshift-install-fips run offline.
#                            Adds about 650 MB of downloads.
#   --image IMAGE            Default: registry.access.redhat.com/ubi9/ubi:latest
#   --skip-negative          Skip the fails-safely checks.
#   --keep                   Keep the work directory and container.
#
# Requires podman, git, curl, sha256sum, tar and python3 on this host, and
# network access for phase 1. Exits non-zero if any check fails.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

REF=""
BUILD_ARGS=()
IMAGE="registry.access.redhat.com/ubi9/ubi:latest"
NEGATIVE=true
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)               REF="$2"; shift 2 ;;
    --pin)               BUILD_ARGS+=(--pin "$2"); shift 2 ;;
    --terraform-version) BUILD_ARGS+=(--terraform-version "$2"); shift 2 ;;
    --openshift-clients) BUILD_ARGS+=(--openshift-clients); shift ;;
    --image)             IMAGE="$2"; shift 2 ;;
    --skip-negative)     NEGATIVE=false; shift ;;
    --keep)              KEEP=true; shift ;;
    -h|--help)           sed -n '3,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                   echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v podman >/dev/null || { echo "ERROR: podman not found in PATH" >&2; exit 2; }
case "$(uname -m)" in
  x86_64)  PLATFORM=linux_amd64 ;;
  aarch64) PLATFORM=linux_arm64 ;;
  *)       echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 2 ;;
esac

WORK="$(mktemp -d -t tf-offline-test.XXXXXX)"
CONTAINER="tf-offline-test-$$"
BUNDLE_NAME="oci-openshift-offline"

cleanup() {
  if [[ "$KEEP" == true ]]; then
    echo
    echo "Kept work dir:  ${WORK}"
    echo "Kept container: ${CONTAINER}   (podman start -ai ${CONTAINER} to rerun)"
  else
    podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# --- Phase 1: connected host -------------------------------------------------

echo "=== Phase 1: connected host (online) — scripts/build-offline-bundle.sh ==="
echo
[[ -n "$REF" ]] && BUILD_ARGS+=(--ref "$REF")
"${REPO_DIR}/scripts/build-offline-bundle.sh" \
  --output "${WORK}/${BUNDLE_NAME}" --platform "$PLATFORM" "${BUILD_ARGS[@]}"

# Nothing installed by the build may reach the bastion except via the tarball.
if tar -tzf "${WORK}/${BUNDLE_NAME}.tgz" | grep -q '/\.terraform/'; then
  echo "ERROR: a .terraform directory leaked into the bundle" >&2
  exit 1
fi

# --- Phase 2: the bastion ----------------------------------------------------

cat > "${WORK}/run-offline.sh" <<'INNER'
#!/bin/bash
set -uo pipefail

NEGATIVE="$1"
BUNDLE="/root/oci-openshift-offline"
REPO="${BUNDLE}/oci-openshift"
FAILS=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
joined() { tr '\n' ' ' <<<"$1"; }   # terraform wraps its error text

echo "--- Environment ---"
if curl -s -m 5 -o /dev/null https://registry.terraform.io/ 2>/dev/null; then
  fail "registry.terraform.io is reachable; this container is not offline"
else
  pass "registry.terraform.io is unreachable"
fi
command -v terraform >/dev/null    && fail "terraform is already installed" || pass "no terraform before install"
[[ -z "${TF_PLUGIN_CACHE_DIR:-}" ]] && pass "no TF_PLUGIN_CACHE_DIR"        || fail "TF_PLUGIN_CACHE_DIR is set"
[[ ! -e /root/.terraform.d ]]      && pass "no ~/.terraform.d"             || fail "~/.terraform.d exists"

echo "--- Unpack and install, as documented ---"
cd /root
if tar -xzf /root/oci-openshift-offline.tgz; then pass "tar -xzf"; else fail "tar -xzf"; exit 1; fi
out=$("${REPO}/scripts/install-offline-bundle.sh" 2>&1); rc=$?
sed 's/^/        /' <<<"$out"
[[ $rc -eq 0 ]] && pass "install-offline-bundle.sh" || fail "install-offline-bundle.sh exited ${rc}"
command -v terraform >/dev/null && pass "terraform installed: $(terraform version | head -1)" || fail "terraform not on PATH after install"

# The doc's block, with its placeholder bundle path replaced by the real one,
# must be exactly what the install script wrote.
# The block may be indented (it sits inside a list), so strip the fence's
# indentation from every line.
doc_rc=$(awk '
  /Create `~\/.terraformrc`/ { f = 1 }
  f && !p && /^ *```hcl/    { p = 1; ind = match($0, /[^ ]/) - 1; next }
  p && /^ *```/             { exit }
  p                         { print substr($0, ind + 1) }' "${REPO}/docs/terraform-offline-init.md" \
  | sed "s|/home/<user>/oci-openshift-offline|${BUNDLE}|")
if [[ -z "$doc_rc" ]]; then
  fail "could not find the ~/.terraformrc block in the doc"
elif [[ "$doc_rc" == "$(cat /root/.terraformrc)" ]]; then
  pass "~/.terraformrc matches docs/terraform-offline-init.md"
else
  # UBI9 has no diff, so show both.
  fail "~/.terraformrc differs from the doc"
  echo "        --- doc (placeholder replaced) ---"; sed 's/^/        /' <<<"$doc_rc"
  echo "        --- written by install script ---"; sed 's/^/        /' /root/.terraformrc
fi

if [[ -d "${BUNDLE}/openshift-clients" ]]; then
  echo "--- OpenShift clients ---"
  for c in "oc version --client" "kubectl version --client" "oc-mirror --v2 version" "openshift-install-fips version"; do
    out=$($c 2>&1) && pass "${c%% *}: $(head -1 <<<"$out")" || { fail "${c%% *} does not run"; sed 's/^/        /' <<<"$out" | tail -5; }
  done
fi

echo "--- Every stack: init pinned by lock file, and validate ---"
for lock in "${REPO}"/terraform-stacks/*/.terraform.lock.hcl; do
  dir=$(dirname "$lock"); s=$(basename "$dir"); cd "$dir"
  want=$(grep -c '^provider ' .terraform.lock.hcl)
  out=$(terraform init -input=false -no-color 2>&1)
  if ! grep -q 'successfully initialized' <<<"$out"; then
    fail "${s}: init"; sed 's/^/        /' <<<"$out" | tail -15; continue
  fi
  got=$(grep -c 'Reusing version .* from the dependency lock file' <<<"$out")
  [[ "$got" -eq "$want" ]] && pass "${s}: init, ${want}/${want} providers pinned" \
                           || fail "${s}: only ${got}/${want} providers reused the lock file"
  out=$(terraform validate -no-color 2>&1)
  grep -q 'Success! The configuration is valid' <<<"$out" && pass "${s}: validate" \
    || { fail "${s}: validate"; sed 's/^/        /' <<<"$out" | tail -15; }
done

echo "--- As an ordinary user, the way disconnected-bastion-setup.md says ---"
# No sudo: binaries go to ~/.local/bin and the config to that user's
# ~/.terraformrc, and a login shell must find terraform on PATH.
useradd -m bastion >/dev/null 2>&1
cp /root/oci-openshift-offline.tgz /home/bastion/ && chown bastion: /home/bastion/oci-openshift-offline.tgz
out=$(su - bastion -c 'tar -xzf oci-openshift-offline.tgz && ./oci-openshift-offline/oci-openshift/scripts/install-offline-bundle.sh' 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "install as user 'bastion'" || { fail "install as user 'bastion' exited ${rc}"; sed 's/^/        /' <<<"$out" | tail -15; }
where=$(su - bastion -c 'command -v terraform' 2>&1)
[[ "$where" == /home/bastion/.local/bin/terraform ]] && pass "login shell finds ${where}" || fail "login shell finds terraform at: ${where:-nothing}"
grep -q '/home/bastion/oci-openshift-offline/tf-provider-mirror' /home/bastion/.terraformrc 2>/dev/null \
  && pass "user's ~/.terraformrc points at their bundle" || fail "user's ~/.terraformrc missing or wrong"
out=$(su - bastion -c 'cd oci-openshift-offline/oci-openshift/terraform-stacks/create-cluster && terraform validate -no-color' 2>&1)
grep -q 'Success! The configuration is valid' <<<"$out" && pass "user can validate create-cluster" \
  || { fail "user cannot validate create-cluster"; sed 's/^/        /' <<<"$out" | tail -8; }

if [[ "$NEGATIVE" == true ]]; then
  echo "--- Fails safely ---"

  # A bundle damaged in transfer must be refused before anything is installed.
  rm -rf /root/corrupt && mkdir /root/corrupt && tar -xzf /root/oci-openshift-offline.tgz -C /root/corrupt
  printf 'x' >> "$(find /root/corrupt -name 'variables.tf' -path '*create-cluster*' | head -1)"
  out=$(/root/corrupt/oci-openshift-offline/oci-openshift/scripts/install-offline-bundle.sh \
        --bin-dir /root/corrupt/bin --cli-config /root/corrupt/terraformrc 2>&1); rc=$?
  if [[ $rc -ne 0 ]] && grep -q 'do not match SHA256SUMS' <<<"$out" && [[ ! -e /root/corrupt/bin/terraform ]]; then
    pass "corrupted bundle refused before installing anything"
  else
    fail "corrupted bundle was not refused (exit ${rc})"; sed 's/^/        /' <<<"$out" | tail -8
  fi

  # create-cluster uses all three providers, so it exercises every case.
  scratch=/root/negative
  rm -rf "$scratch"; cp -r "$REPO" "$scratch"
  cd "$scratch/terraform-stacks/create-cluster"
  rc_for() {  # rc_for MIRROR -> a CLI config pointing at MIRROR
    sed "s|${BUNDLE}/tf-provider-mirror|$1|" /root/.terraformrc > "/root/rc-$(basename "$1")"
    echo "/root/rc-$(basename "$1")"
  }

  # A provider whose contents changed after the lock file was written. Terraform
  # verifies the h1: hash, which covers the files inside the package, so the
  # change must be to the contents: bytes appended after the end of the zip
  # change no provider code and are correctly accepted.
  cp -r "${BUNDLE}/tf-provider-mirror" /root/mirror-tampered
  python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "a").writestr("tampered", "x")' \
    "$(find /root/mirror-tampered -name 'terraform-provider-time_*.zip')"
  rm -rf .terraform
  out=$(TF_CLI_CONFIG_FILE=$(rc_for /root/mirror-tampered) terraform init -input=false -no-color 2>&1)
  grep -q "doesn't match any of the checksums previously recorded" <<<"$(joined "$out")" \
    && pass "tampered provider rejected by lock file checksum" \
    || { fail "tampered provider was NOT rejected"; sed 's/^/        /' <<<"$out" | tail -10; }

  # A provider missing from the mirror must fail fast and be named.
  cp -r "${BUNDLE}/tf-provider-mirror" /root/mirror-partial
  rm -rf /root/mirror-partial/registry.terraform.io/hashicorp/external
  rm -rf .terraform
  start=$(date +%s)
  out=$(TF_CLI_CONFIG_FILE=$(rc_for /root/mirror-partial) terraform init -input=false -no-color 2>&1)
  took=$(( $(date +%s) - start ))
  grep -q 'hashicorp/external was not.*found in any of the search locations' <<<"$(joined "$out")" \
    && pass "missing provider reported by name (${took}s)" \
    || { fail "missing provider not reported clearly"; sed 's/^/        /' <<<"$out" | tail -10; }
  [[ "$took" -lt 30 ]] || fail "missing-provider failure took ${took}s; looks like a network timeout"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL (${FAILS} check(s))"; fi
exit "$FAILS"
INNER

echo
echo "=== Phase 2: bastion (UBI9, --network=none, only the tarball copied in) ==="
podman image exists "$IMAGE" || podman pull -q "$IMAGE" >/dev/null
podman create --name "$CONTAINER" --network=none "$IMAGE" /bin/bash /root/run-offline.sh "$NEGATIVE" >/dev/null
podman cp "${WORK}/${BUNDLE_NAME}.tgz" "${CONTAINER}:/root/${BUNDLE_NAME}.tgz"
podman cp "${WORK}/run-offline.sh"     "${CONTAINER}:/root/run-offline.sh"
podman start --attach "$CONTAINER"
