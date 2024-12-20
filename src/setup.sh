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

  if ! setup_ups; then
    logError "Failed to setup UPS"
    return 1
  fi

  # Hide PCI devices from dom0, as they will be passed to VMs
  local res
  passthrough_configure
  res=$?
  if [[ ${res} -ne 0 ]]; then
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

setup_ups() {
  # Prepare configuration
  local nut_script="${DQ_ROOT}/src/lifecycle/nut_handler.sh"
  local driver_file="${DQ_ROOT}/data/ups/ups.conf"
  local daemon_file="${DQ_ROOT}/data/ups/upsd.conf"
  local user_file="${DQ_ROOT}/data/ups/upsd.users"
  local monitor_file="${DQ_ROOT}/data/ups/upsmon.conf"
  local scheduler_file="${DQ_ROOT}/data/ups/upssched.conf"

  # Make sure each of these files exists
  if [[ ! -f "${nut_script}" ]]; then
    logError "NUT handler script not found"
    return 1
  fi
  if [[ ! -f "${driver_file}" ]]; then
    logError "UPS driver configuration file not found"
    return 1
  fi
  if [[ ! -f "${daemon_file}" ]]; then
    logError "UPS daemon configuration file not found"
    return 1
  fi
  if [[ ! -f "${user_file}" ]]; then
    logError "UPS user configuration file not found"
    return 1
  fi
  if [[ ! -f "${monitor_file}" ]]; then
    logError "UPS monitor configuration file not found"
    return 1
  fi
  if [[ ! -f "${scheduler_file}" ]]; then
    logError "UPS scheduler configuration file not found"
    return 1
  fi

  # Install script
  local nut_script_dest="${BIN_DIR}/nut_handler"
  if [[ -L "${nut_script_dest}" ]]; then
    if [[ "$(readlink "${nut_script_dest}")" == "${nut_script}" ]]; then
      logInfo "${nut_script} already symlinked"
    else
      logError "${nut_script} is not symlinked to ${nut_script_dest}"
      return 1
    fi
  elif [[ -f "${nut_script_dest}" ]]; then
    logError "A ${nut_script} file already exists"
    return 1
  else
    if ! ln -s "${nut_script}" "${nut_script_dest}"; then
      logError "Failed to create ${nut_script} simlink"
      return 1
    else
      logInfo "Created symlink to ${nut_script} successfully"
    fi
  fi

  # Load configuration files
  local driver_content
  local daemon_content
  local user_content
  local monitor_content
  local scheduler_content

  driver_content=$(cat "${driver_file}")
  daemon_content=$(cat "${daemon_file}")
  user_content=$(cat "${user_file}")
  monitor_content=$(cat "${monitor_file}")
  scheduler_content=$(cat "${scheduler_file}")

  # Configure NUT by making dynamic repplaces for the @value@ tags in the files
  monitor_content="${monitor_content//"@NOTIFY_CMD@"/"${nut_script_dest} event -- "}"
  monitor_content="${monitor_content//"@SHUTDOWN_CMD@"/"${nut_script_dest} shutdown"}"

  scheduler_content="${scheduler_content//"@SCHED_CMD@"/"${nut_script_dest} timer -- "}"
  scheduler_content="${scheduler_content//"@PIPEFN@"/"/var/run/nut/upssched.pipe"}"
  scheduler_content="${scheduler_content//"@LOCKFN@"/"/var/run/nut/upssched.lock"}"

  # Configure NUT
  if ! nut_setup "netserver" driver_content daemon_content user_content monitor_content scheduler_content; then
    logError "Failed to configure NUT"
    return 1
  fi

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
DQ_ME="$(basename "${BASH_SOURCE[0]}")"

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
XE_LIB_DIR="${DQ_ROOT}/external/xapi.sh"
if ! source "${SETUP_REPO_DIR}/external/slf4.sh/src/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
if ! source "${SETUP_REPO_DIR}/external/config.sh/src/config.sh"; then
  logFatal "Failed to import config.sh"
fi
if ! source "${SETUP_REPO_DIR}/src/git.sh"; then
  logFatal "Failed to import git.sh"
fi
if ! source "${SETUP_REPO_DIR}/src/sops.sh"; then
  logFatal "Failed to import sops.sh"
fi
if ! source "${SETUP_REPO_DIR}/src/age.sh"; then
  logFatal "Failed to import age.sh"
fi
if ! source "${SETUP_REPO_DIR}/src/nut.sh"; then
  logFatal "Failed to import nut.sh"
fi
if ! source "${XE_LIB_DIR}/src/xe_network.sh"; then
  logFatal "Failed to import xe_network.sh"
fi
if ! source "${DQ_ROOT}/src/hal/identity.sh"; then
  logFatal "Failed to import identity.sh"
fi
if ! source "${DQ_ROOT}/src/aq113c/aq113c.sh"; then
  logFatal "Failed to import aq113c.sh"
fi
if ! source "${DQ_ROOT}/src/hal/sensors.sh"; then
  logFatal "Failed to import sensors.sh"
fi
if ! source "${DQ_ROOT}/src/hal/qnap_hal.sh"; then
  logFatal "Failed to import qnap_hal.sh"
fi
if ! source "${DQ_ROOT}/src/email/email.sh"; then
  logFatal "Failed to import email.sh"
fi
if ! source "${DQ_ROOT}/src/raid/mdadm.sh"; then
  logFatal "Failed to import mdadm.sh"
fi
if ! source "${DQ_ROOT}/src/raid/smartd.sh"; then
  logFatal "Failed to import smartd.sh"
fi
if ! source "${DQ_ROOT}/src/lifecycle/daemon.sh"; then
  logFatal "Failed to import daemon.sh"
fi
if ! source "${DQ_ROOT}/src/iommu/passthrough.sh"; then
  logFatal "Failed to import passthrough.sh"
fi

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  setup "${@}"
  exit $?
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  logFatal "This script cannot be sourced"
else
  # This script was executed
  setup "${@}"
  exit $?
fi
