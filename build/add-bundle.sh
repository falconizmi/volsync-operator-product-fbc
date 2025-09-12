#! /bin/bash

set -e

if [[ $(basename "${PWD}") != "volsync-operator-product-fbc" ]]; then
  echo "error: Script must be run from the base of the repository."
  exit 1
fi

bundle_image=${1}

if [[ -z "${bundle_image}" ]]; then
  echo "error: the bundle image to be added must be provided as a positional argument."
  exit 1
fi

# Validate bundle image format
if [[ ! "${bundle_image}" =~ ^quay\.io/redhat-user-workloads/volsync-tenant/volsync-bundle-[0-9]+-[0-9]+@sha256:[a-f0-9]+$ ]]; then
  echo "error: the bundle image must follow the pattern:"
  echo "  ./build/add-bundle.sh quay.io/redhat-user-workloads/volsync-tenant/volsync-bundle-X-Y@sha256:<sha>"
  exit 1
fi

# Parse bundle
bundle_json=$(skopeo inspect --override-os=linux --override-arch=amd64 "docker://${bundle_image}")
bundle_digest=$(echo "${bundle_json}" | jq -r ".Digest")
bundle_version=$(echo "${bundle_json}" | jq -r ".Labels.version")
bundle_channels=$(echo "${bundle_json}" | jq -r '.Labels["operators.operatorframework.io.bundle.channels.v1"]')

echo "* Found bundle: ${bundle_digest}"
echo "* Found version: ${bundle_version}"
echo "* Found channels: ${bundle_channels}"

if [[ -n $(yq '.entries[] | select(.image == "'"${bundle_image}"'")' catalog-template.yaml) ]]; then
  echo "error: bundle entry already exists."
  exit 1
fi

# Add bundle
bundle_entry="
  image: ${bundle_image}
  schema: olm.bundle
" yq '.entries += env(bundle_entry)' -i catalog-template.yaml

# Add bundle to channels
for channel in ${bundle_channels//,/ }; do
  echo "  Adding to channel: ${channel}"
  if [[ -z $(yq '.entries[] | select(.schema == "olm.channel") | select(.name == "'"${channel}"'")' catalog-template.yaml) ]]; then
    #latest_channel=$(yq '.entries[] | select(.schema == "olm.channel").name' catalog-template.yaml | grep -v stable | sort --version-sort | tail -1)
    #new_channel=$(yq '.entries[] | select(.name == "'"${latest_channel}"'") | .name = "'"${channel}"'"' catalog-template.yaml)
    #echo "  Creating new ${channel} channel from ${latest_channel}"

    echo "  Creating new ${channel} channel ..."
    new_channel="
      name: ${channel}
      package: volsync-product
      schema: olm.channel
      entries: []
    "
    new_channel=${new_channel} yq '.entries += env(new_channel)' -i catalog-template.yaml
  fi

  # Check if this version already exists in the channel
  existing_entry=$(yq '.entries[] | select(.schema == "olm.channel") | select(.name == "'"${channel}"'").entries[] | select(.name == "volsync-product.'"${bundle_version}"'")' catalog-template.yaml)

  if [[ -n "${existing_entry}" ]]; then
    echo "    Version ${bundle_version} already exists in channel ${channel}, skipping entries update"
    continue
  fi

  entries_in_channel=$(yq '.entries[] | select(.schema == "olm.channel") | select(.name == "'"${channel}"'").entries | length' catalog-template.yaml)
  if [[ "${entries_in_channel}" == "0" ]]; then
    # No previous version - this is the first
    echo "    Adding first version to entries (no replaces version)"
    channel_entry="
      name: volsync-product.${bundle_version}
      skipRange: '>=0.4.0 <${bundle_version#v}'
    "
  else
    # Add to end first - we'll sort later
    echo "    Adding new version to end of entries"
    channel_entry="
      name: volsync-product.${bundle_version}
      skipRange: '>=0.4.0 <${bundle_version#v}'
    "
  fi

  # Add the entry to the end
  channel_entry=${channel_entry} yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries += env(channel_entry)' -i catalog-template.yaml

  # Now sort the entries by version and rebuild replaces chain
  echo "    Sorting entries and fixing replaces chain"

  # Sort entries in place by name (which includes version)
  yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries |= sort_by(.name)' -i catalog-template.yaml

  # Rebuild replaces chain - get sorted entry names
  sorted_names=$(yq '.entries[] | select(.schema == "olm.channel") | select(.name == "'"${channel}"'").entries[].name' catalog-template.yaml)

  # Clear replaces fields first, then rebuild the chain
  yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries[] |= del(.replaces)' -i catalog-template.yaml

  previous_name=""
  while IFS= read -r current_name; do
    if [[ -n "${current_name}" && -n "${previous_name}" ]]; then
      # Add replaces field right after name to maintain field order (name, replaces, skipRange)
      yq '.entries[] |= select(.schema == "olm.channel") |= select(.name == "'"${channel}"'").entries[] |= select(.name == "'"${current_name}"'") |= .name as $n | .replaces = "'"${previous_name}"'" | . = {"name": $n, "replaces": .replaces} + del(.name, .replaces)' -i catalog-template.yaml
    fi
    previous_name="${current_name}"
  done <<< "${sorted_names}"
done
