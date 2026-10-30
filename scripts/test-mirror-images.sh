#!/bin/bash
set -euo pipefail

# Tests that every container image a disconnected install needs can actually be
# pulled with oc-mirror, and that it lands where this repo's terraform will
# redirect the cluster to look for it.
#
# Uses docs/imageset-config.yaml and a throwaway local registry. Three checks:
#
#   1. Dry run of the whole imageset. Confirms the OpenShift release and any
#      operator catalogs resolve with your pull secret, and records where
#      oc-mirror would put every image.
#
#   2. Real mirror of every additionalImages entry into the local registry,
#      then a check that each one is there. A dry run does not do this: it
#      happily maps a tag that does not exist.
#
#   3. Layout. With private_registry set to the oc-mirror destination, the
#      create-cluster stack generates imageDigestSources for the release and
#      an ImageTagMirrorSet for the repositories in tag_mirrored_repos
#      (terraform-stacks/shared_modules/manifest/locals.tf). Every one of
#      those redirects must point at a path oc-mirror actually populated,
#      and every mirrored image must have a redirect.
#
# The release payload itself (15-20 GB) is only resolved, not downloaded,
# unless --full is given.
#
# Usage:
#   ./test-mirror-images.sh --authfile FILE [--config FILE] [--full] [--keep]
#
#   --authfile FILE   Pull secret (Red Hat pull secret JSON). Required:
#                     several images come from registry.redhat.io.
#   --config FILE     ImageSetConfiguration. Default: docs/imageset-config.yaml
#   --full            Also mirror the release and operators for real into the
#                     local registry. Needs the disk space and the time.
#   --keep            Keep the work directory and the local registry.
#
# Requires podman, curl, python3 and network access. oc-mirror is used from
# PATH if present, otherwise downloaded and checksum-verified.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

AUTHFILE=""
CONFIG="${REPO_DIR}/docs/imageset-config.yaml"
FULL=false
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --authfile) AUTHFILE="$2"; shift 2 ;;
    --config)   CONFIG="$2"; shift 2 ;;
    --full)     FULL=true; shift ;;
    --keep)     KEEP=true; shift ;;
    -h|--help)  sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$AUTHFILE" ]] || { echo "ERROR: --authfile is required" >&2; exit 2; }
[[ -r "$AUTHFILE" ]] || { echo "ERROR: cannot read ${AUTHFILE}" >&2; exit 2; }
[[ -r "$CONFIG" ]]   || { echo "ERROR: cannot read ${CONFIG}" >&2; exit 2; }
for cmd in podman curl python3; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found in PATH" >&2; exit 2; }
done
AUTHFILE="$(cd "$(dirname "$AUTHFILE")" && pwd)/$(basename "$AUTHFILE")"

WORK="$(mktemp -d -t mirror-test.XXXXXX)"
REGISTRY="mirror-test-registry-$$"
cleanup() {
  if [[ "$KEEP" == true ]]; then
    echo
    echo "Kept work dir: ${WORK}"
    echo "Kept registry: ${REGISTRY} at localhost:${PORT:-?}  (podman rm -f ${REGISTRY})"
  else
    podman rm -f "$REGISTRY" >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

FAILS=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }

# --- oc-mirror ---------------------------------------------------------------

if command -v oc-mirror >/dev/null; then
  OC_MIRROR="$(command -v oc-mirror)"
else
  base="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.22"
  curl -fsSL -o "${WORK}/oc-mirror.rhel9.tar.gz" "${base}/oc-mirror.rhel9.tar.gz"
  curl -fsSL -o "${WORK}/sha256sum.txt"          "${base}/sha256sum.txt"
  (cd "$WORK" && grep ' oc-mirror.rhel9.tar.gz$' sha256sum.txt | sha256sum -c --quiet -) \
    || { echo "ERROR: oc-mirror download does not match the mirror's sha256sum.txt" >&2; exit 1; }
  tar -xzf "${WORK}/oc-mirror.rhel9.tar.gz" -C "$WORK" oc-mirror
  chmod 0755 "${WORK}/oc-mirror"
  OC_MIRROR="${WORK}/oc-mirror"
fi

# oc-mirror runs an embedded registry that reads every REGISTRY_* environment
# variable as its own configuration. REGISTRY_AUTH_FILE in particular makes it
# crash, so pass credentials with --authfile and clear the rest.
for v in $(env | grep -oE '^REGISTRY_[A-Z_]+' || true); do unset "$v"; done

# --- Local registry ----------------------------------------------------------

PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
DEST="localhost:${PORT}"
podman run -d --rm --name "$REGISTRY" -p "127.0.0.1:${PORT}:5000" docker.io/library/registry:2 >/dev/null
for _ in $(seq 1 20); do
  curl -fs -o /dev/null "http://${DEST}/v2/" && break
  sleep 0.5
done
curl -fs -o /dev/null "http://${DEST}/v2/" || { echo "ERROR: local registry did not start" >&2; exit 1; }

echo "Config:    ${CONFIG#"${REPO_DIR}"/}"
echo "oc-mirror: $("$OC_MIRROR" --v2 version 2>/dev/null | grep -oE 'GitVersion:"[^"]+"' | cut -d'"' -f2)"
echo "Registry:  ${DEST}  (stands in for private_registry)"

oc_mirror() {  # oc_mirror CONFIG WORKSPACE LOG [extra args]
  local cfg="$1" ws="$2" log="$3"; shift 3
  "$OC_MIRROR" --v2 -c "$cfg" --authfile "$AUTHFILE" --workspace "file://${ws}" \
    "docker://${DEST}" --dest-tls-verify=false "$@" > "$log" 2>&1
}

# --- 1. Dry run of everything ------------------------------------------------

echo
echo "--- 1. Dry run: release, operators and additional images resolve ---"
if oc_mirror "$CONFIG" "${WORK}/ws-dry" "${WORK}/dry-run.log" --dry-run; then
  MAPPING="$(find "${WORK}/ws-dry" -name mapping.txt | head -1)"
  pass "dry run completed; $(wc -l < "$MAPPING") images mapped"
else
  fail "dry run failed"; grep -E 'ERROR|error' "${WORK}/dry-run.log" | tail -8 | sed 's/^/        /'
  MAPPING=""
fi

# --- 2. Mirror the additional images for real --------------------------------

echo
echo "--- 2. Every additionalImages entry can actually be pulled ---"
python3 -I - "$CONFIG" "${WORK}/additional-only.yaml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
out = {"kind": "ImageSetConfiguration", "apiVersion": cfg["apiVersion"],
       "mirror": {"additionalImages": cfg["mirror"]["additionalImages"]}}
yaml.safe_dump(out, open(sys.argv[2], "w"))
PY
if oc_mirror "${WORK}/additional-only.yaml" "${WORK}/ws-add" "${WORK}/additional.log"; then
  pass "oc-mirror reported success"
else
  fail "oc-mirror failed"; grep -E 'ERROR|error' "${WORK}/additional.log" | tail -8 | sed 's/^/        /'
fi
# Check each image really arrived, at the path the redirects will use.
while read -r img; do
  repo="${img%:*}"; tag="${img##*:}"; path="${repo#*/}"
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://${DEST}/v2/${path}/manifests/${tag}")
  [[ "$code" == 200 ]] && pass "${img}" || fail "${img}  (not at ${DEST}/${path}:${tag}, HTTP ${code})"
done < <(python3 -I -c 'import sys, yaml; [print(i["name"]) for i in yaml.safe_load(open(sys.argv[1]))["mirror"]["additionalImages"]]' "$CONFIG")

# --- 3. Layout matches what terraform generates ------------------------------

echo
echo "--- 3. Terraform's redirects point where oc-mirror put things ---"
python3 -I - "${REPO_DIR}/terraform-stacks/shared_modules/manifest/locals.tf" "$CONFIG" "$DEST" "${MAPPING}" > "${WORK}/layout.txt" <<'PY'
import re, sys, yaml
locals_tf, config, dest, mapping = sys.argv[1:5]
src = open(locals_tf).read()

# Repositories the generated ImageTagMirrorSet redirects, and the path each
# one is redirected to: private_registry + the path minus the registry host.
blk = src[src.index("tag_mirrored_repos = concat("):]
blk = blk[:blk.index("])")]
repos = set(re.findall(r'"([a-z0-9.\-]+(?::[0-9]+)?/[^"]+)"', blk))
m = re.search(r'default_oci_driver_image\s*=\s*"([^"]+)"', src)
if m:
    repos.add(m.group(1).rsplit(":", 1)[0])          # oci_driver_repo
if len(repos) < 5:
    print("FAIL could not read tag_mirrored_repos from locals.tf"); sys.exit()

mirrored = {i["name"].rsplit(":", 1)[0] for i in yaml.safe_load(open(config))["mirror"]["additionalImages"]}
for r in sorted(repos - mirrored):
    print(f"FAIL ImageTagMirrorSet redirects {r} but the imageset does not mirror it")
for r in sorted(mirrored - repos):
    print(f"FAIL the imageset mirrors {r} but no ImageTagMirrorSet entry redirects it")

# Release: terraform's imageDigestSources send these two sources here.
if mapping:
    lines = [l.strip() for l in open(mapping) if "=" in l]
    want = {"quay.io/openshift-release-dev/ocp-release": f"{dest}/openshift/release-images",
            "quay.io/openshift-release-dev/ocp-v4.0-art-dev": f"{dest}/openshift/release"}
    for source, target in want.items():
        got = {l.split("=", 1)[1].replace("docker://", "").rsplit(":", 1)[0].split("@")[0]
               for l in lines if l.startswith(f"docker://{source}")}
        if not got:
            print(f"FAIL dry run mapped nothing from {source}")
        elif got == {target}:
            print(f"PASS {source} -> {target}")
        else:
            print(f"FAIL {source} mapped to {sorted(got)}, terraform expects {target}")
else:
    print("FAIL no dry-run mapping to check the release layout against")

print(f"PASS {len(repos & mirrored)} redirected repositories, all mirrored" if repos == mirrored else "")
PY
while read -r verdict rest; do
  [[ -z "$verdict" ]] && continue
  if [[ "$verdict" == PASS ]]; then pass "$rest"; else fail "$rest"; fi
done < "${WORK}/layout.txt"

# --- Optional: everything for real -------------------------------------------

if [[ "$FULL" == true ]]; then
  echo
  echo "--- Full mirror: release and operators ---"
  if oc_mirror "$CONFIG" "${WORK}/ws-full" "${WORK}/full.log"; then
    pass "full mirror into ${DEST} completed"
  else
    fail "full mirror failed"; grep -E 'ERROR|error' "${WORK}/full.log" | tail -8 | sed 's/^/        /'
  fi
fi

echo
if [[ "$FAILS" -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL (${FAILS} check(s))"; fi
exit "$FAILS"
