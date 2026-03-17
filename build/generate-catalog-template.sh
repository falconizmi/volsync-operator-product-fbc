#! /bin/bash

set -e

if [[ $(basename "${PWD}") != "volsync-operator-product-fbc" ]]; then
  echo "error: Script must be run from the base of the repository."
  exit 1
fi

echo "Using drop version Volsync-Product map:"
jq '.' drop-versions.json

ocp_versions=$(jq -r 'keys[]' drop-versions.json)

shouldPrune() {
  # decision when to prune, is based on the value of ocp keys in drop-versions.json where variables:
  # prune_until
  # - is representing the value of volsync version, until which version (inclusive) the script will be pruning
  # - another way of understanding it, is from which version (not inclusive) the script will STOP the pruning 
  # prune_from
  # - is representing the value of volsync version, from which version (not inclusive) the script will be pruning
  # - another way of understanding it, is until which version (inclusive) the script will BE NOT pruning 
  # 

  prune_until="$(jq -r ".[\"${1}\"][\"prune_until\"]" drop-versions.json).99"
  prune_from="$(jq -r ".[\"${1}\"][\"prune_from\"]" drop-versions.json).99"

  [[ "$(printf "%s\n%s\n" "${2}" "${prune_until}" | sort --version-sort | tail -1)" == "${prune_until}" || \
     ("${prune_from}" != ".99" && "$(printf "%s\n%s\n" "${2}" "${prune_from}" | sort --version-sort | head -1)" == "${prune_from}")
  ]]

  return $?
}

for version in ${ocp_versions}; do
  cp catalog-template.yaml "catalog-template-${version//./-}.yaml"
done

# Prune old X.Y channels
echo "# Pruning channels:"
for channel in $(yq '.entries[] | select(.schema == "olm.channel").name' catalog-template.yaml); do
  echo "  Found channel: ${channel}"
  for ocp_version in ${ocp_versions}; do
    # Special case, acm-2.6 channel was only there until OCP 4.14
    if [ "${channel}" == "acm-2.6" ]; then
      if [ "${ocp_version}" != "4.14" ]; then
        echo "  - Pruning channel from OCP ${ocp_version}: ${channel} ..."
        yq '.entries[] |= select(.schema == "olm.channel") |= del(select(.name == "'"${channel}"'"))' -i "catalog-template-${ocp_version//./-}.yaml"
      fi
      continue
    fi

    if [ "${channel}" == "stable" ]; then
      for bundle in $(yq '.entries[] | select(.name == "stable").entries[].name' catalog-template.yaml); do
        if shouldPrune "${ocp_version}" "${bundle#*.v}"; then 
          echo "  - Pruning bundle from channel ${channel}: ${bundle} ..."
          yq '.entries[] |= select(.name == "stable").entries[] |= del(select(.name == "'"${bundle}"'"))' -i "catalog-template-${ocp_version//./-}.yaml"
        fi
      done
      #TODO is that all?? Check how is stable removed when this new if block is removed
      #TODO what if stable is empty (not likely but consider it)
      continue
    fi

    if shouldPrune "${ocp_version}" "${channel#*\-}"; then
      echo "  - Pruning channel from OCP ${ocp_version}: ${channel} ..."
      yq '.entries[] |= select(.schema == "olm.channel") |= del(select(.name == "'"${channel}"'"))' -i "catalog-template-${ocp_version//./-}.yaml"

      continue
    fi

    # Prune old bundles from channels
    for entry in $(yq '.entries[] | select(.schema == "olm.channel") | select(.name == "'"${channel}"'").entries[].name' catalog-template.yaml); do
      version=${entry#*\.v}
      if shouldPrune "${ocp_version}" "${version}"; then
        echo "  - Pruning entry from OCP ${ocp_version}: ${entry}"
        yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries[] |= del(select(.name == "'"${entry}"'"))' -i "catalog-template-${ocp_version//./-}.yaml"
      fi

    done

    # Always remove "replaces" field from first entry (as there is nothing to replace)
    echo "  - OCP: ${ocp_version} CHANNEL: ${channel} - removing replaces from first entry"
    yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries[0] |= del(.replaces)' -i "catalog-template-${ocp_version//./-}.yaml"
  done
done
echo

# Prune old bundles
echo "# Pruning bundles:"
for bundle_image in $(yq '.entries[] | select(.schema == "olm.bundle").image' catalog-template.yaml); do
  if ! bundle_json=$(skopeo inspect --override-os=linux --override-arch=amd64 "docker://${bundle_image}"); then
    echo "Tip: The repository might be not in a clean state."
    exit 1
  fi
  bundle_version=$(echo "${bundle_json}" | jq -r ".Labels.version")
  echo "  Found version: ${bundle_version}"
  pruned=0
  for ocp_version in ${ocp_versions}; do
    if shouldPrune "${ocp_version}" "${bundle_version#v}"; then
      echo "  - Pruning bundle ${bundle_version} from OCP ${ocp_version} ..."
      echo "    (image ref: ${bundle_image})"
      yq '.entries[] |= select(.schema == "olm.bundle") |= del(select(.image == "'"${bundle_image}"'"))' -i "catalog-template-${ocp_version//./-}.yaml"
    else
      ((pruned += 1))
    fi
  done
  #if ((pruned == $(jq 'keys | length' drop-versions.json))); then
  #  echo "  Nothing pruned--exiting."
  #  break
  #fi
done
