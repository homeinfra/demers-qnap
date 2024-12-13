#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script is used to configure the qnap machine
#
# Currently tested on XCP-ng 8.3 (CentOS)

setup() {
  if ! setup_dependencies; then
    logError "Failed to setup dependencies"
    return 1
  fi

  if ! setup_host_hardware; then
    logError "Failed to setup host hardware"
    return 1
  fi

  if ! local_xcp_config; then
    logError "Failed to configure local XCP-ng"
    return 1
  fi

  if [[ ${REBOOT_REQUIRED} -eq 1 ]]; then
    logInfo "Rebooting..."
    shutdown -r now
  fi

  return 0
}

setup_dependencies() {
  # Load install configuration
  if ! config_load "${DQ_ROOT}/data/local.env"; then
    logError "Failed to load install configuration"
    return 1
  fi

  # Make sure git is installed and configured
  if ! git_install; then
    logInfo "Failed to install git"
    return 1
  fi
  if ! git_configure "${DQ_ROOT}"; then
    logInfo "Failed to configure git"
    return 1
  fi

  # Install and configure configuration cyphering
  if ! sops_install; then
    logInfo "Failed to install sops"
    return 1
  fi
  if ! age_install; then
    logInfo "Failed to install age"
    return 1
  fi
  if ! age_configure "${AGE_KEY}"; then
    logInfo "Failed to configure age"
    return 1
  fi

  return 0
}

setup_host_hardware() {
  config_load "${DQ_ROOT}/data/hardware.env"

  # Make sure we are executing on the right system
  if ! check_system; then
    logError "This script is not supported on this system"
    return 1
  fi

  # TODO: Configure partitions

  # Install drivers for the 10 GBe NIC
  if ! aq113c_install; then
    logInfo "Failed to install AQ113C drivers"
    return 1
  fi

  if ! validate_hardware; then
    logError "Failed to validate hardware"
    return 1
  fi

  # Configure sensors
  if ! sensor_install; then
    logError "Failed to install sensors"
    return 1
  fi

  # Configure QNAP HAL
  if ! qnap_hal_install; then
    logError "Failed to install QNAP HAL"
    return 1
  fi

  # Test hardware by using the buzzer
  if ! qhal beep Online; then
    logError "Failed to test buzzer"
    return 1
  fi

  # TODO: UPS configuration

  # Hide PCI devices from dom0, as they will be passed to VMs
  local res
  passthrough_configure
  res=$?
  if ! ${res}; then
    if [[ ${res} -eq 2 ]]; then
      logInfo "Reboot required"
      REBOOT_REQUIRED=1
    else
      logError "Failed to configure PCI passthrough"
      return 1
    fi
  fi
  logInfo "PCI passthrough configured"

  return 0
}

# Validate hardware
validate_hardware() {
  # Validate network interfaces
  local macs=()
  local nic
  for nic in ${NICS}; do
    nic="${nic}_MAC"
    if [[ -n "${!nic}" ]]; then
      macs+=("${!nic}")
    else
      logError "Variable ${nic} is not set or empty"
      return 1
    fi
  done

  if xe_validate_nic "${macs[@]}"; then
    logInfo "All network interfaces exist"
  else
    logError "At least one NIC is invalid"
    return 1
  fi

  return 0
}

check_system() {
  local name
  if id_identify name; then
    if [[ "${name}" == "${QN_NAME}" ]]; then
      return 0
    fi
  fi

  return 1
}

local_xcp_config() {
  # Configure emails
  if ! email_install; then
    logError "Failed to install email configuration"
    return 1
  fi

  # Configure Boot drive monitoring
  if ! sd_configure; then
    logError "Failed to install smartd"
    return 1
  fi
  if ! md_configure; then
    logError "Failed to install mdadm"
    return 1
  fi

  # Configure the lifecycle daemon
  if ! deamon_configure; then
    logError "Failed to configure the lifecycle daemon"
    return 1
  fi

  if ! enable_power_button; then
    logError "Failed to enable power button"
    return 1
  fi

  #TODO: Local ISO storage

  #TODO: Local VM storage
  
  #TODO: NetData agent

  return 0
}

# Constants
AGE_KEY="homeinfra_demers"
REBOOT_REQUIRED=0

###########################
###### Startup logic ######
###########################

DQ_ARGS=("$@")
DQ_CWD=$(pwd)
DQ_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
DQ_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${DQ_SOURCE}" ]]; do # resolve $DQ_SOURCE until the file is no longer a symlink
  DQ_ROOT=$(cd -P "$(dirname "${DQ_SOURCE}")" >/dev/null 2>&1 && pwd)
  DQ_SOURCE=$(readlink "${DQ_SOURCE}")
  [[ ${DQ_SOURCE} != /* ]] && DQ_SOURCE=${DQ_ROOT}/${DQ_SOURCE} # if $DQ_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DQ_ROOT=$(cd -P "$(dirname "${DQ_SOURCE}")" >/dev/null 2>&1 && pwd)
DQ_ROOT=$(realpath "${DQ_ROOT}/..")

# Import dependencies
SETUP_REPO_DIR="${DQ_ROOT}/external/setup"
XE_LIB_DIR="${DQ_ROOT}/libs/xenapi"
source ${SETUP_REPO_DIR}/src/slf4sh.sh
source ${SETUP_REPO_DIR}/src/git.sh
source ${SETUP_REPO_DIR}/src/sops.sh
source ${SETUP_REPO_DIR}/src/age.sh
source ${SETUP_REPO_DIR}/src/config.sh
source ${XE_LIB_DIR}/src/xe_network.sh
source ${DQ_ROOT}/src/hal/identity.sh
source ${DQ_ROOT}/src/aq113c/aq113c.sh
source ${DQ_ROOT}/src/hal/sensors.sh
source ${DQ_ROOT}/src/hal/qnap_hal.sh
source ${DQ_ROOT}/src/email/email.sh
source ${DQ_ROOT}/src/raid/mdadm.sh
source ${DQ_ROOT}/src/raid/smartd.sh
source ${DQ_ROOT}/src/lifecycle/daemon.sh
source ${DQ_ROOT}/src/iommu/passthrough.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  setup "${@}"
  exit $?
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  echo "ERROR: This script cannot be sourced"
  exit 1
else
  # This script was executed
  setup "${@}"
  exit $?
fi
