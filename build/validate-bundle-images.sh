#! /bin/bash
# Validates catalog-template.yaml:
#
#   1. TEMPLATE RENDERING — opm renders the template without error, catching
#      broken YAML, missing fields, invalid upgrade graphs, and unreachable images.
#
#   2. IMAGE EXISTENCE — every olm.bundle image is reachable via skopeo inspect.
#      If an image is not found at its primary URL, falls back to quay.io mirrors
#      defined in .tekton/images-mirror-set.yaml using longest-prefix matching.
#      Images found only on a mirror are treated as a warning (unreleased).
#
# Mirror fallback follows the same approach as the Konflux community task:
# https://github.com/konflux-ci/community-catalog/tree/main/tasks/validate-fbc-images-resolvable
#
# Requires registry credentials via REGISTRY_AUTH_FILE env var or skopeo login.
#
# Requires: bash, yq, opm, skopeo

set -eo pipefail

MIRROR_SET=".tekton/images-mirror-set.yaml"

if [[ ! -f "catalog-template.yaml" ]]; then
  echo "error: catalog-template.yaml not found. Script must be run from the base of the repository."
  exit 1
fi

# Load mirror sources and their first mirror from the ImageDigestMirrorSet
mirror_sources=()
mirror_targets=()
if [[ -f "${MIRROR_SET}" ]]; then
  mapfile -t mirror_sources < <(yq '.spec.imageDigestMirrors[].source' "${MIRROR_SET}")
  mapfile -t mirror_targets < <(yq '.spec.imageDigestMirrors[].mirrors[0]' "${MIRROR_SET}")
  echo "=== Loaded ${#mirror_sources[@]} mirror source(s) from ${MIRROR_SET} ==="
else
  echo "=== WARNING: ${MIRROR_SET} not found — mirror fallback disabled ==="
fi

echo ""
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

  if timeout 60 skopeo inspect --override-os=linux --override-arch=amd64 "docker://${bundle_image}" > /dev/null 2>&1; then
    echo "  -> OK: available at primary URL"
    continue
  fi

  echo "  -> Not found at primary URL, checking mirrors ..."
  image_repo="${bundle_image%%@*}"
  image_digest="${bundle_image##*@}"

  # Longest-prefix matching against mirror sources
  best_match_source=""
  best_match_mirror=""
  for i in "${!mirror_sources[@]}"; do
    source="${mirror_sources[$i]}"
    if [[ "${image_repo}" == "${source}"* && ${#source} -gt ${#best_match_source} ]]; then
      best_match_source="${source}"
      best_match_mirror="${mirror_targets[$i]}"
    fi
  done

  if [[ -z "${best_match_source}" ]]; then
    echo "  -> ERROR: no mirror configured for ${image_repo}"
    failed=1
    continue
  fi

  image_suffix="${image_repo#"${best_match_source}"}"
  resolved_url="${best_match_mirror}${image_suffix}@${image_digest}"
  echo "  -> Trying mirror: ${resolved_url}"

  if timeout 60 skopeo inspect --override-os=linux --override-arch=amd64 "docker://${resolved_url}" > /dev/null 2>&1; then
    echo "  -> WARNING: found on mirror but not at primary URL (unreleased)"
    warned=$((warned + 1))
  else
    echo "  -> ERROR: not found at primary URL or mirror: ${bundle_image}"
    failed=1
  fi
done < <(yq '.entries[] | select(.schema == "olm.bundle") | .name + " " + .image' catalog-template.yaml)

if [[ ${warned} -gt 0 ]]; then
  echo ""
  echo "NOTE: ${warned} image(s) found on mirror only — expected for unreleased bundles."
fi

if [[ ${failed} -ne 0 ]]; then
  echo ""
  echo "ERROR: One or more bundle images are missing or inaccessible."
  exit 1
fi

echo ""
echo "=== All bundle images verified ==="
