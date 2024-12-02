#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# API for XCP-ng network configuration

# Known NICs on this system
NIC_0_MAC="00:08:9b:ef:8d:72" # Used for Management and WOL
NIC_1_MAC="00:08:9b:ef:8d:73" # Unused
NIC_2_MAC="24:5e:be:86:05:e9" # Expansion card (10 GbE)

test() {
  if nw_validate_nic "${NIC_0_MAC}" "${NIC_1_MAC}" "${NIC_2_MAC}"; then
    logInfo "All network interfaces exist"
  else
    echo "ERROR: At least one NIC is invalid"
    return 1
  fi
  return 0
}

# Checks if the provided NICs exists
#
# Parameters:
#   $@[in]: NICs to validate
# Returns:
#   0: If all NICs are valid
#   1: If any NIC is invalid
nw_validate_nic() {
  local _macs="$@"

  local HOST_ID
  if ! hs_current_host HOST_ID; then
    logError "Failed to get host"
    return 1
  fi

  # Force a rescan of interfaces
  if ! xe ${XE_LOGIN} pif-scan host-uuid=${HOST_ID}; then
    logError "Failed to scan for PIFs"
    return 1
  fi

  local mac
  for mac in $_macs; do
    logTrace "Checking if a NIC with MAC address ${mac} exists"
    if ! nw_identify_nic "${mac}"; then
      logError "NIC with MAC ${mac} not found"
      return 1
    else
      local details
      stringify_array details
      logInfo <<EOF
==== NIC ${array['device']} found ====${details}
EOF
    fi
  done

  return 0
}

# Perform lookup of a NIC from it's MAC address
#
# Parameters:
#   $1[in]: MAC address to lookup
nw_identify_nic() {
  local _mac="$1"

  local res
  if ! res=$(xe ${XE_LOGIN} pif-list MAC="${_mac}"); then
    logError "Failed to execute search"
  elif [[ -z "${res}" ]]; then
    logError "NIC not found"
  else
    xe_parse_params "$res"
  fi
}

###########################
###### Startup logic ######
###########################

NW_ARGS=("$@")
NW_CWD=$(pwd)
NW_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
NW_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${NW_SOURCE}" ]]; do # resolve $NW_SOURCE until the file is no longer a symlink
  NW_ROOT=$(cd -P "$(dirname "${NW_SOURCE}")" >/dev/null 2>&1 && pwd)
  NW_SOURCE=$(readlink "${NW_SOURCE}")
  [[ ${NW_SOURCE} != /* ]] && NW_SOURCE=${NW_ROOT}/${NW_SOURCE} # if $NW_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
NW_ROOT=$(cd -P "$(dirname "${NW_SOURCE}")" >/dev/null 2>&1 && pwd)
NW_ROOT=$(realpath "${NW_ROOT}/..")

# Import dependencies
source ${NW_ROOT}/../../external/setup/src/slf4sh.sh
source ${NW_ROOT}/src/host.sh
source ${NW_ROOT}/src/xe_utils.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  echo "ERROR: This script cannot be piped"
  exit 1
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  # echo "ERROR: This script cannot be executed"
  # exit 1
  test
  exit $?
fi