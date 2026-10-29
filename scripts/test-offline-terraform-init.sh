#!/bin/bash
set -euo pipefail

# Tests the disconnected terraform init procedure in docs/terraform-offline-init.md
# inside a UBI9 container that has no network at all.
#
# Phase 1 runs on this host, online, and plays the "connected host": it
# initializes every stack to write lock files, then builds a provider mirror
# with 'terraform providers mirror'.
#
# Phase 2 plays the "bastion": a fresh UBI9 container started with
# --network=none. Nothing is mounted. The terraform binary, the repo with its
# lock files, the mirror, and the .terraformrc are copied in with 'podman cp'
# before the container starts, the way a bundle is carried to a real bastion.
# Every stack must then init and validate.
#
# The .terraformrc is extracted from the doc itself, so this tests what the doc
# tells people to type rather than a private copy of it.
#
# Usage:
#   ./test-offline-terraform-init.sh [--ref REV] [--image IMAGE] [--skip-negative] [--keep]
#
#   --ref REV         Test a specific commit. Default: the working tree,
#                     including uncommitted changes to tracked files.
#   --image IMAGE     Default: registry.access.redhat.com/ubi9/ubi:latest
#   --skip-negative   Skip the checks that the procedure fails safely
#                     (tampered provider, missing provider).
#   --keep            Keep the work directory and container for inspection.
#
# Requires podman, git, terraform and python3 on this host, and network access for
# phase 1. Exits non-zero if any check fails.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOC="docs/terraform-offline-init.md"

REF=""
IMAGE="registry.access.redhat.com/ubi9/ubi:latest"
NEGATIVE=true
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)           REF="$2"; shift 2 ;;
    --image)         IMAGE="$2"; shift 2 ;;
    --skip-negative) NEGATIVE=false; shift ;;
    --keep)          KEEP=true; shift ;;
    -h|--help)       sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

for cmd in podman git terraform python3; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found in PATH" >&2; exit 2; }
done

TF_BIN="$(command -v terraform)"
if ! file -L "$TF_BIN" | grep -q 'statically linked'; then
  echo "ERROR: ${TF_BIN} is not statically linked and may not run inside UBI9" >&2
  exit 2
fi

case "$(uname -m)" in
  x86_64)  PLATFORM=linux_amd64 ;;
  aarch64) PLATFORM=linux_arm64 ;;
  *)       echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 2 ;;
esac

WORK="$(mktemp -d -t tf-offline-test.XXXXXX)"
CONTAINER="tf-offline-test-$$"

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

# --- Which tree to test ------------------------------------------------------

cd "$REPO_DIR"
if [[ -z "$REF" ]]; then
  # 'git stash create' makes a commit of the working tree without touching
  # it, so uncommitted edits are tested too. It prints nothing when the tree
  # is clean. Untracked files are not included.
  REF="$(git stash create)"
  REF="${REF:-HEAD}"
  DESC="working tree ($(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo ' + uncommitted changes'))"
else
  DESC="$(git rev-parse --short "$REF")"
fi

echo "Testing:   ${DESC}"
echo "Image:     ${IMAGE}"
echo "Terraform: $("$TF_BIN" version | head -1)"
echo "Platform:  ${PLATFORM}"
echo "Work dir:  ${WORK}"

# The doc's .terraformrc, with its placeholder home directory pointed at the
# container's.
RC_BLOCK="$(git show "${REF}:${DOC}" | awk '
  /Create `~\/.terraformrc`/ { f = 1 }
  f && /^```hcl/            { p = 1; next }
  p && /^```/               { exit }
  p')"
if [[ -z "$RC_BLOCK" ]]; then
  echo "ERROR: could not find the ~/.terraformrc block in ${DOC}" >&2
  exit 1
fi
printf '%s\n' "$RC_BLOCK" | sed 's|/home/<user>/|/root/|' > "${WORK}/terraformrc"
if grep -q '<' "${WORK}/terraformrc"; then
  echo "ERROR: unexpanded placeholder left in the extracted .terraformrc:" >&2
  cat "${WORK}/terraformrc" >&2
  exit 1
fi

# --- Phase 1: connected host -------------------------------------------------

echo
echo "=== Phase 1: connected host (online) ==="

mkdir -p "${WORK}/connected" "${WORK}/bundle/oci-openshift-mine"
git archive "$REF" | tar -x -C "${WORK}/connected"
git archive "$REF" | tar -x -C "${WORK}/bundle/oci-openshift-mine"

# Every stack directory: anything under terraform-stacks/ with .tf files,
# except the shared modules. Discovered, not listed, so new stacks are tested
# without editing this script.
mapfile -t STACKS < <(
  cd "${WORK}/connected/terraform-stacks" &&
  for d in */; do
    d="${d%/}"
    [[ "$d" == shared_modules ]] && continue
    compgen -G "${d}/*.tf" >/dev/null && echo "$d"
  done
)
echo "Stacks: ${STACKS[*]}"

# Keep this host's own terraform config and plugin cache out of it: an empty
# CLI config and no cache dir, so providers really come from the registry.
: > "${WORK}/empty-terraformrc"
export TF_CLI_CONFIG_FILE="${WORK}/empty-terraformrc"
unset TF_PLUGIN_CACHE_DIR TF_DATA_DIR

for s in "${STACKS[@]}"; do
  echo "  init (online):      ${s}"
  terraform -chdir="${WORK}/connected/terraform-stacks/${s}" \
    init -backend=false -input=false -no-color > "${WORK}/connected-init-${s}.log" 2>&1 \
    || { echo "ERROR: online init failed for ${s}:" >&2; tail -20 "${WORK}/connected-init-${s}.log" >&2; exit 1; }
done

for s in "${STACKS[@]}"; do
  echo "  providers mirror:   ${s}"
  terraform -chdir="${WORK}/connected/terraform-stacks/${s}" \
    providers mirror -platform="$PLATFORM" "${WORK}/tf-provider-mirror" > "${WORK}/mirror-${s}.log" 2>&1 \
    || { echo "ERROR: providers mirror failed for ${s}:" >&2; tail -20 "${WORK}/mirror-${s}.log" >&2; exit 1; }
done

unset TF_CLI_CONFIG_FILE

# The bundle is a clean checkout plus only the lock files. The connected
# copy's .terraform directories already hold installed providers; shipping
# them would make the offline init pass without ever touching the mirror.
for s in "${STACKS[@]}"; do
  cp "${WORK}/connected/terraform-stacks/${s}/.terraform.lock.hcl" \
     "${WORK}/bundle/oci-openshift-mine/terraform-stacks/${s}/"
done
if find "${WORK}/bundle" -name .terraform -type d | grep -q .; then
  echo "ERROR: a .terraform directory leaked into the bundle" >&2
  exit 1
fi

echo "Mirrored providers:"
(cd "${WORK}/connected/terraform-stacks" &&
  grep -h -A1 '^provider' */.terraform.lock.hcl | grep -E 'provider|version' | paste - - | sort -u \
    | sed -E 's/provider "registry.terraform.io\/([^"]+)".*version += "([^"]+)"/    \1 \2/')
echo "Mirror size: $(du -sh "${WORK}/tf-provider-mirror" | cut -f1)"

if [[ "$NEGATIVE" == true ]]; then
  # A mirror whose 'time' package has had a file added after the lock file
  # was written. The lock file's checksums must catch it.
  #
  # The change has to be to the package contents. Terraform verifies the h1:
  # hash, which covers the files inside the zip, so bytes appended after the
  # end of the archive change the zip's sha256 but not a line of provider
  # code, and are correctly accepted.
  cp -r "${WORK}/tf-provider-mirror" "${WORK}/mirror-tampered"
  python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "a").writestr("tampered", "x")' \
    "$(find "${WORK}/mirror-tampered" -name 'terraform-provider-time_*.zip')"

  # A mirror missing one provider entirely. Init must fail fast and name it,
  # not hang trying the network.
  cp -r "${WORK}/tf-provider-mirror" "${WORK}/mirror-partial"
  rm -rf "${WORK}/mirror-partial/registry.terraform.io/hashicorp/external"
fi

# --- Phase 2: the bastion ----------------------------------------------------

cat > "${WORK}/run-offline.sh" <<'INNER'
#!/bin/bash
set -uo pipefail

NEGATIVE="$1"; shift
STACKS=("$@")
FAILS=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }

echo "--- Environment ---"
if curl -s -m 5 -o /dev/null https://registry.terraform.io/ 2>/dev/null; then
  fail "registry.terraform.io is reachable; this container is not offline"
else
  pass "registry.terraform.io is unreachable"
fi
[[ -z "${TF_PLUGIN_CACHE_DIR:-}" ]] && pass "no TF_PLUGIN_CACHE_DIR" || fail "TF_PLUGIN_CACHE_DIR is set"
[[ ! -e /root/.terraform.d ]]      && pass "no ~/.terraform.d"      || fail "~/.terraform.d exists"
terraform version >/dev/null 2>&1  && pass "terraform runs: $(terraform version | head -1)" || fail "terraform does not run"

echo "--- Doc procedure: init and validate every stack ---"
for s in "${STACKS[@]}"; do
  cd "/root/oci-openshift-mine/terraform-stacks/${s}" || { fail "${s}: missing from bundle"; continue; }
  want=$(grep -c '^provider ' .terraform.lock.hcl)
  out=$(terraform init -input=false -no-color 2>&1)
  if ! grep -q 'successfully initialized' <<<"$out"; then
    fail "${s}: init failed"; sed 's/^/        /' <<<"$out" | tail -15; continue
  fi
  reused=$(grep -c 'Reusing version .* from the dependency lock file' <<<"$out")
  if [[ "$reused" -eq "$want" ]]; then
    pass "${s}: init, ${want}/${want} providers pinned by lock file"
  else
    fail "${s}: only ${reused}/${want} providers reused the lock file"
  fi
  out=$(terraform validate -no-color 2>&1)
  if grep -q 'Success! The configuration is valid' <<<"$out"; then
    pass "${s}: validate"
  else
    fail "${s}: validate"; sed 's/^/        /' <<<"$out" | tail -15
  fi
done

if [[ "$NEGATIVE" == true ]]; then
  echo "--- Fails safely ---"
  # create-cluster uses all three providers, so it exercises every case.
  scratch=/root/negative
  rm -rf "$scratch"; cp -r /root/oci-openshift-mine "$scratch"
  cd "$scratch/terraform-stacks/create-cluster"

  rm -rf .terraform
  out=$(TF_CLI_CONFIG_FILE=/root/terraformrc-tampered terraform init -input=false -no-color 2>&1)
  # Terraform wraps its error text, so join lines before matching.
  if grep -q "doesn't match any of the checksums previously recorded" <<<"$(tr '\n' ' ' <<<"$out")"; then
    pass "tampered provider rejected by lock file checksum"
  else
    fail "tampered provider was NOT rejected"; sed 's/^/        /' <<<"$out" | tail -10
  fi

  rm -rf .terraform
  start=$(date +%s)
  out=$(TF_CLI_CONFIG_FILE=/root/terraformrc-partial terraform init -input=false -no-color 2>&1)
  took=$(( $(date +%s) - start ))
  if grep -q 'hashicorp/external was not.*found in any of the search locations' <<<"$(tr '\n' ' ' <<<"$out")"; then
    pass "missing provider reported by name (${took}s)"
  else
    fail "missing provider not reported clearly"; sed 's/^/        /' <<<"$out" | tail -10
  fi
  [[ "$took" -lt 30 ]] || fail "missing-provider failure took ${took}s; looks like a network timeout"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL (${FAILS} check(s))"; fi
exit "$FAILS"
INNER

echo
echo "=== Phase 2: bastion (UBI9, --network=none, nothing mounted) ==="

podman image exists "$IMAGE" || podman pull -q "$IMAGE" >/dev/null

podman create --name "$CONTAINER" --network=none \
  "$IMAGE" /bin/bash /root/run-offline.sh "$NEGATIVE" "${STACKS[@]}" >/dev/null

podman cp "$TF_BIN"                              "${CONTAINER}:/usr/local/bin/terraform"
podman cp "${WORK}/bundle/oci-openshift-mine"    "${CONTAINER}:/root/"
podman cp "${WORK}/tf-provider-mirror"           "${CONTAINER}:/root/"
podman cp "${WORK}/terraformrc"                  "${CONTAINER}:/root/.terraformrc"
podman cp "${WORK}/run-offline.sh"               "${CONTAINER}:/root/run-offline.sh"

if [[ "$NEGATIVE" == true ]]; then
  podman cp "${WORK}/mirror-tampered" "${CONTAINER}:/root/"
  podman cp "${WORK}/mirror-partial"  "${CONTAINER}:/root/"
  sed 's|/root/tf-provider-mirror|/root/mirror-tampered|' "${WORK}/terraformrc" > "${WORK}/terraformrc-tampered"
  sed 's|/root/tf-provider-mirror|/root/mirror-partial|'  "${WORK}/terraformrc" > "${WORK}/terraformrc-partial"
  podman cp "${WORK}/terraformrc-tampered" "${CONTAINER}:/root/terraformrc-tampered"
  podman cp "${WORK}/terraformrc-partial"  "${CONTAINER}:/root/terraformrc-partial"
fi

echo ".terraformrc used (extracted from ${DOC}):"
sed 's/^/    /' "${WORK}/terraformrc"
echo

podman start --attach "$CONTAINER"
