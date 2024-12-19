#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Script executed on shutdown to make sure everything happens orderly

shutdown_main() {
  logInfo "Shutting down..."
  shutdown_init

  # If we reach here, the system really is going down

  if [[ -f "${SHUTDOWN_CMD_FILE}" ]]; then
    SH_CMD=$(cat ${SHUTDOWN_CMD_FILE})
    rm -f ${SHUTDOWN_CMD_FILE}
  else
    SH_CMD="${SHUTDOWN_LOCAL}"
    warn "No shutdown command found. Assuming: ${SH_CMD}"
  fi
  if [[ "${SH_CMD}" == "${SHUTDOWN_LOCAL}" ]]; then
    info "Shutting down locally"
    if ! ${HOME_BIN}/qhal beep Error; then
      logError "Failed to buzz indicating local shutdown"
    fi
    shutdown_local
  elif [[ "${SH_CMD}" == "${SHUTDOWN_ALL}" ]]; then
    info "Shutting down all"
    if ! ${HOME_BIN}/qhal beep Outage; then
      logError "Failed to buzz indicating all shutdown"
    fi
    shutdown_all
  else
    error "Unknown shutdown command: ${SH_CMD}. Perfoming a local shudown only"
    shutdown_local
  fi

  logInfo "Shutdown complete. Letting the OS handle the rest"
}

shutdown_local() {
  notify_wait_sol
}

shutdown_all() {
  notify_wait_sol
}

notify_wait_sol() {
  # Notify SOL we are going down, wait for the OK
  : # TODO: Wait on SOL being ready
}

shutdown_init() {
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
  if ! config_load "${SH_ROOT}/data/local.env"; then
    logError "Failed to load local configuration"
  fi
  if ! config_load "${CONFIG_DIR}/email.env"; then
    logError "Failed to load QNAP configuration"
  fi

  sh_parse
}

sh_parse() {
  local short="he"
  local long="help,execute"

  local opts
  opts=$(getopt --options ${short} --long ${long} --name "${SH_ME}" -- "${SH_ARGS[@]}")
  if [[ $? -ne 0 ]]; then
    error "Failed to parse arguments"
    exit 1
  fi

  local cmd
  local opt

  eval set -- "${opts}"
  while true; do
    case "$1" in
      -h|--help)
        sh_print_usage
        exit 0
        ;;
      -e|--execute)
        opt="-e"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        error "Unknown option: $1"
        exit 1
        ;;
    esac
  done

  # Handle positional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      all|local)
        cmd=${1}
        shift
        ;;
      *)
        error "Unknown or too many argument: $1"
        exit 1
        ;;
    esac
  done

  if [[ -n "${cmd}" ]]; then
    logInfo "Mark system ${cmd} for shutdown"
    echo ${SHUTDOWN_ALL} > ${SHUTDOWN_CMD_FILE}
    if [[ "${cmd}" == "${SHUTDOWN_ALL}" ]]; then
      if [[ "${opt}" == "-e" ]]; then
        logInfo "Trigger the shutdown"
        /sbin/shutdown -h +0
        if [[ $? -ne 0 ]]; then
          error "Failed to trigger shutdown"
        else
          logInfo "Shutdown triggered"
        fi
      else
        logInfo "No shutdown triggered."
      fi
    fi
    # If we were doing some marking, don't process further
    exit 0
  fi
}

sh_print_usage() {
  cat <<EOF
Shutdown the system

Usage: ${SH_ME} [OPTION] [{all,local}]

Options:
  -h, --help    Display this help and exit
  -e, --execute Trigger the shutdown as well as marking all systems for shutdown
Arguments:
  all         Mark all systems for shutdown
  local       Mark only this system for shutdown [default]
EOF
}

info() {
  logInfo "$1"

  xe message-create name="Shutdown" body="$1" priority=${LVL_INFO} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

warn() {
  logWarn "$1"

  xe message-create name="Shutdown" body="$1" priority=${LVL_WARN} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

error() {
  logError "$1"

  xe message-create name="Shutdown" body="$1" priority=${LVL_ERROR} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

# Constants
SHUTDOWN_CMD_FILE="/tmp/shutdown.cmd"
SHUTDOWN_LOCAL="local"
SHUTDOWN_ALL="all"

# XCP-ng message levels
LVL_ERROR=1
LVL_WARN=2
LVL_INFO=3
LVL_DEBUG=4
LVL_TRACE=5

###########################
###### Startup logic ######
###########################
SH_ARGS=("$@")
SH_CWD=$(pwd)
SH_ME="$(basename "${BASH_SOURCE[0]}")"

# Get directory of this script
# https://stackoverflow.com/a/246128
SH_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${SH_SOURCE}" ]]; do # resolve $SH_SOURCE until the file is no longer a symlink
  SH_ROOT=$(cd -P "$(dirname "${SH_SOURCE}")" >/dev/null 2>&1 && pwd)
  SH_SOURCE=$(readlink "${SH_SOURCE}")
  [[ ${SH_SOURCE} != /* ]] && SH_SOURCE=${SH_ROOT}/${SH_SOURCE} # if $SH_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SH_ROOT=$(cd -P "$(dirname "${SH_SOURCE}")" >/dev/null 2>&1 && pwd)
SH_ROOT=$(realpath "${SH_ROOT}/../..")

# Import dependencies
LOG_CONSOLE=0
SETUP_REPO_DIR="${SH_ROOT}/external/setup"
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
  shutdown_main
  exit $?
fi
