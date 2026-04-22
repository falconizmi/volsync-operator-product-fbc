#! /bin/bash
# Validates catalog-template.yaml:
#
#   1. TEMPLATE RENDERING — opm renders the template without error, catching
#      broken YAML, missing fields, invalid upgrade graphs, and unreachable images.
#
#   2. IMAGE EXISTENCE — every olm.bundle image is reachable via skopeo inspect.
#      Images added in the current PR (not present in the base branch) produce
#      a warning instead of a failure, since they may not yet be mirrored to
#      the official registry.
#
# Optional: set BASE_CATALOG to a path containing the base branch's
# catalog-template.yaml to enable new-image detection.
#
# Requires registry credentials (e.g. skopeo login registry.redhat.io, or a pull secret).
#
# Requires: bash, yq, opm, skopeo

set -eo pipefail

if [[ ! -f "catalog-template.yaml" ]]; then
  echo "error: catalog-template.yaml not found. Script must be run from the base of the repository."
  exit 1
fi

base_images=""
if [[ -n "${BASE_CATALOG}" && -f "${BASE_CATALOG}" ]]; then
  base_images=$(yq '.entries[] | select(.schema == "olm.bundle") | .image' "${BASE_CATALOG}")
  echo "=== Base branch catalog loaded — new images will be warned, not failed ==="
  echo ""
fi

echo "=== Step 1: Rendering catalog-template.yaml (opm) ==="
if ! opm alpha render-template basic catalog-template.yaml -o yaml > /dev/null; then
  echo ""
  echo "ERROR: catalog-template.yaml failed to render."
  echo "Check the template for malformed entries, missing fields, or unreachable images."
  exit 1
fi
echo "  Template rendered successfully."

echo ""
echo "=== Step 2: Checking bundle images in catalog-template.yaml ==="
failed=0
warned=0
while IFS=' ' read -r bundle_name bundle_image; do
  echo "  Checking ${bundle_name} ..."
  if ! skopeo inspect --override-os=linux --override-arch=amd64 "docker://${bundle_image}" > /dev/null; then
    if [[ -n "${base_images}" ]] && ! echo "${base_images}" | grep -qF "${bundle_image}"; then
      echo "  WARNING: ${bundle_name} — new image not yet in registry (expected): ${bundle_image}"
      warned=$((warned + 1))
    else
      echo "  ERROR: ${bundle_name} — image not found or inaccessible: ${bundle_image}"
      failed=1
    fi
  fi
done < <(yq '.entries[] | select(.schema == "olm.bundle") | .name + " " + .image' catalog-template.yaml)

if [[ ${warned} -gt 0 ]]; then
  echo ""
  echo "NOTE: ${warned} new image(s) not yet in registry — this is expected for unreleased bundles."
fi

if [[ ${failed} -ne 0 ]]; then
  echo ""
  echo "ERROR: One or more existing bundle images are missing or inaccessible."
  exit 1
fi

echo ""
echo "=== All bundle images verified ==="
