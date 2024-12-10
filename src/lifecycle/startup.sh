#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Script executed on startup to configure the system on bootup

startup_main() {
  logInfo "Starting up..."

  if ! res=$(xe host-list name-label=$(hostname) --minimal); then
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

  # Start HAL deamon
  if ! qnap_hal local hal_daemon -f; then
    error "Failed to start HAL daemon"
  fi

  # Register USB Copy Button to perform a total shutdown
  # TODO

  # Startup complete
  if ! qhal beep Online; then
    error "Failed to buzz indicating startup complete"
  fi

  logInfo "Startup complete"
  return 0
}


  # # Load configuration
  # if ! config_load "${ST_ROOT}/data/install.env"; then
  #   logError "Failed to load install configuration"
  # fi
  # if ! config_load "${CONFIG_DIR}/email.env"; then
  #   logError "Failed to load QNAP configuration"
  # fi

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
ST_ME="$(basename "$0")"

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
source ${SETUP_REPO_DIR}/src/slf4sh.sh
source ${SETUP_REPO_DIR}/src/config.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  echo "ERROR: This script cannot be piped"
  exit 1
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  echo "ERROR: This script cannot be sourced"
  exit 1
else
  # This script was executed
  startup_main
  exit $?
fi
