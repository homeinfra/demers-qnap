#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Configures PCI passthrough for peripherals that will be passed through VMs

# Returns:
#   0: Success
#   1: Failure
#   2: Reboot required
passthrough_configure() {
  if [[ -z "${QN_STORAGE_PASS_THROUGH}" ]]; then
    warn "No PCI passthrough configuration found"
    return 1
  fi

  local pciback_arg
  local pci_array
  local IFS=','
  # Read the input string into an array
  read -ra pci_array <<< "$QN_STORAGE_PASS_THROUGH"
  for pci in "${pci_array[@]}"; do
    local desc
    desc=$(lspci -s "${pci}")
    logInfo "Configuring PCI passthrough for ${desc}"
    pciback_arg+="(0000:${pci})"
  done
  logTrace "Boot config: ${pciback_arg}"

  local cur
  if ! cur=$("/opt/xensource/libexec/xen-cmdline" --get-dom0 "xen-pciback.hide"); then
    logError "Failed to get current grub configuration"
    return 1
  elif [[ -z "${cur}" ]]; then
    logInfo "No current configuration found"
  elif [[ "${cur}" == "xen-pciback.hide=${pciback_arg}" ]]; then
    logInfo "Configuration already set"
    return 0
  fi

  # If we reach here, configuration is necessary
  if ! sudo "/opt/xensource/libexec/xen-cmdline" --set-dom0 "xen-pciback.hide=${pciback_arg}"; then
    logError "Failed to set configuration"
    return 1
  else
    logInfo "Pci passthrough configuration set"
    return 2
  fi
}

###########################
###### Startup logic ######
###########################
PI_ARGS=("$@")
PI_CWD=$(pwd)
PI_ME="$(basename "${BASH_SOURCE[0]}")"

# Get directory of this script
# https://stackoverflow.com/a/246128
PI_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${PI_SOURCE}" ]]; do # resolve $PI_SOURCE until the file is no longer a symlink
  PI_ROOT=$(cd -P "$(dirname "${PI_SOURCE}")" >/dev/null 2>&1 && pwd)
  PI_SOURCE=$(readlink "${PI_SOURCE}")
  [[ ${PI_SOURCE} != /* ]] && PI_SOURCE=${PI_ROOT}/${PI_SOURCE} # if $PI_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
PI_ROOT=$(cd -P "$(dirname "${PI_SOURCE}")" >/dev/null 2>&1 && pwd)
PI_ROOT=$(realpath "${PI_ROOT}/../..")

# Import dependencies
SETUP_REPO_DIR="${PI_ROOT}/external/setup"
if ! source "${SETUP_REPO_DIR}/external/slf4.sh/src/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
if ! source "${SETUP_REPO_DIR}/external/config.sh/src/config.sh"; then
  echo "Failed to import config.sh"
  exit 1
fi

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  logFatal "This script cannot be piped"
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  logFatal "This script cannot be executed"
fi
