#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# API for XCP-ng network configuration

if [[ -z ${GUARD_XE_NETWORK_SH} ]]; then
  GUARD_XE_NETWORK_SH=1
else
  return
fi

# Checks if the provided NICs exists
#
# Parameters:
#   $@[in]: NICs to validate
# Returns:
#   0: If all NICs are valid
#   1: If any NIC is invalid
xe_validate_nic() {
  local _macs="$@"

  local HOST_ID
  if ! xe_current_host HOST_ID; then
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
    if ! xe_identify_nic "${mac}"; then
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
xe_identify_nic() {
  local _mac="$1"

  local res
  if ! res=$(xe ${XE_LOGIN} pif-list MAC="${_mac}"); then
    logError "Failed to execute search"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "NIC not found"
    return 1
  else
    xe_parse_params "$res"
    return 0
  fi
}

###########################
###### Startup logic ######
###########################

XN_ARGS=("$@")
XN_CWD=$(pwd)
XN_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
XN_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${XN_SOURCE}" ]]; do # resolve $XN_SOURCE until the file is no longer a symlink
  XN_ROOT=$(cd -P "$(dirname "${XN_SOURCE}")" >/dev/null 2>&1 && pwd)
  XN_SOURCE=$(readlink "${XN_SOURCE}")
  [[ ${XN_SOURCE} != /* ]] && XN_SOURCE=${XN_ROOT}/${XN_SOURCE} # if $XN_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
XN_ROOT=$(cd -P "$(dirname "${XN_SOURCE}")" >/dev/null 2>&1 && pwd)
XN_ROOT=$(realpath "${XN_ROOT}/..")

# Import dependencies
source ${XN_ROOT}/../../external/setup/src/slf4sh.sh
source ${XN_ROOT}/src/xe_host.sh
source ${XN_ROOT}/src/xe_utils.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  echo "ERROR: This script cannot be piped"
  exit 1
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  echo "ERROR: This script cannot be executed"
  exit 1
fi