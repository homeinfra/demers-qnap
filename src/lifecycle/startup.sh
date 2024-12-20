#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Script executed on startup to configure the system on bootup

startup_main() {
  logInfo "Starting up..."
  startup_init

  hardware_init

  # Startup complete
  if ! ${HOME_BIN}/qhal beep Online; then
    error "Failed to buzz indicating startup complete"
  fi

  info "Startup complete"
  return 0
}

hardware_init() {
  # Initialize HAL
  if ! qnap_hal_init; then
    error "Failed to start HAL daemon"
  fi

  # Start HAL daemon
  if ! ${HOME_BIN}/qhal start; then
    error "Failed to start QNAP HAL"
  fi

  # Register USB Copy Button to perform a total shutdown
  local sh_cmd="${ST_ROOT}/src/lifecycle/shutdown.sh"
  if ! ${HOME_BIN}/qhal button USB_Copy -- ${sh_cmd} -e all; then
    error "Failed to register USB Copy button for full shutdown"
  else
    logInfo "Registered USB Copy button for full shutdown"
  fi
}

startup_init() {
  if ! command -v xe &> /dev/null; then
    logError "XCP-ng tools not found"
    return 1
  elif ! res=$(xe host-list name-label=$(hostname) --minimal); then
    logError "Failed to get host"
    exit 1
  elif [[ -z "${res}" ]]; then
    logError "Host not found"
    exit 1
  elif [[ "${res}" == *","* ]]; then
    logError "Multiple hosts found"
    exit 1
  else
    logTrace "Host identified: ${res}"
    HOST_ID=${res}
  fi

  # Load configuration
  if ! config_load "${ST_ROOT}/data/local.env"; then
    logError "Failed to load local configuration"
  fi
  if ! config_load "${CONFIG_DIR}/email.env"; then
    logError "Failed to load QNAP configuration"
  fi
}

info() {
  logInfo "$1"

  xe message-create name="Startup" body="$1" priority=${LVL_INFO} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

warn() {
  logWarn "$1"

  xe message-create name="Startup" body="$1" priority=${LVL_WARN} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

error() {
  logError "$1"

  xe message-create name="Startup" body="$1" priority=${LVL_ERROR} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

# Constants

# XCP-ng message levels
LVL_ERROR=1
LVL_WARN=2
LVL_INFO=3
LVL_DEBUG=4
LVL_TRACE=5

###########################
###### Startup logic ######
###########################
ST_ARGS=("$@")
ST_CWD=$(pwd)
ST_ME="$(basename "${BASH_SOURCE[0]}")"

# Get directory of this script
# https://stackoverflow.com/a/246128
ST_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${ST_SOURCE}" ]]; do # resolve $ST_SOURCE until the file is no longer a symlink
  ST_ROOT=$(cd -P "$(dirname "${ST_SOURCE}")" >/dev/null 2>&1 && pwd)
  ST_SOURCE=$(readlink "${ST_SOURCE}")
  [[ ${ST_SOURCE} != /* ]] && ST_SOURCE=${ST_ROOT}/${ST_SOURCE} # if $ST_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
ST_ROOT=$(cd -P "$(dirname "${ST_SOURCE}")" >/dev/null 2>&1 && pwd)
ST_ROOT=$(realpath "${ST_ROOT}/../..")

# Import dependencies
SETUP_REPO_DIR="${ST_ROOT}/external/setup"
if ! source "${SETUP_REPO_DIR}/external/slf4.sh/src/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
if ! source "${SETUP_REPO_DIR}/external/config.sh/src/config.sh"; then
  logFatal "Failed to import config.sh"
fi
if ! source "${ST_ROOT}/src/hal/qnap_hal.sh"; then
  logFatal "Failed to import qnap_hal.sh"
fi

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  logFatal "This script cannot be piped"
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  logFatal "This script cannot be sourced"
else
  # This script was executed
  startup_main
  exit $?
fi
