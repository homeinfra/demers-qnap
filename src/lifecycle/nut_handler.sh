#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script handles integration with NUT (Network UPS Tools)

nut_main() {
  if ! nut_init; then
    logError "Failed to initialize"
    return 1
  fi

  if ! nut_parse; then
    logError "Failed to parse arguments"
    return 1
  fi
}

nut_init() {
  logInfo "Handling a NUT call: ${UP_ARGS[@]}"

  if ! command -v xe &> /dev/null; then
    logError "XCP-ng tools not found"
    return 1
  elif ! res=$(xe host-list name-label=$(hostname) --minimal); then
    logError "Failed to get host"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "Host not found"
    return 1
  elif [[ "${res}" == *","* ]]; then
    logError "Multiple hosts found"
    return 1
  else
    logTrace "Host identified: ${res}"
    HOST_ID=${res}
  fi

  # Load configuration
  if ! config_load "${UP_ROOT}/data/local.env"; then
    logError "Failed to load local configuration"
    return 1
  fi
  if ! config_load "${CONFIG_DIR}/email.env"; then
    logError "Failed to load QNAP configuration"
    return 1
  fi
}

# Handle NUT event
# As documented by the NOTIFYCMD https://networkupstools.org/docs/man/upsmon.html
nut_event() {
  local not_type="${NOTIFYTYPE}"
  local not_ups="${UPSNAME}"
  local not_msg="${1}"

  logInfo "Handling UPS event: ${not_type} (${not_ups}): ${not_msg}"

  case "${not_type}" in
    ONLINE)
      "${SCHED_CMD}" "$@"
      if [[ $? -ne 0 ]]; then
        error "Failed to invoke upssched for ${not_type}"
      fi
      notify_event "${not_msg}"
      ${HOME_BIN}/qhal beep Online
      ;;
    ONBATT)
      "${SCHED_CMD}" "$@"
      if [[ $? -ne 0 ]]; then
        error "Failed to invoke upssched for ${not_type}"
      fi
      notify_event "${not_msg}"
      ${HOME_BIN}/qhal beep Outage
      ;;
    LOWBATT)
      warn "Battery is critically low: ${not_msg}"
      notify_event "${not_msg}"
      ;;
    FSD)
      notify_event "${not_msg}"
      ;;
    COMMOK)
      # logTrace "Communication restored with ${not_ups}: ${not_msg}"
      notify_event "${not_msg}"
      ;;
    COMMBAD)
      notify_event "${not_msg}"
      ;;
    SHUTDOWN)
      notify_event "${not_msg}"
      ;;
    REPLBATT)
      notify_event "${not_msg}"
      ;;
    NOCOMM)
      notify_event "${not_msg}"
      ;;
    NOPARENT)
      notify_event "${not_msg}"
      ;;
    CAL)
      notify_event "${not_msg}"
      ;;
    NOTCAL)
      notify_event "${not_msg}"
      ;;
    OFF)
      notify_event "${not_msg}"
      ;;
    NOTOFF)
      notify_event "${not_msg}"
      ;;
    BYPASS)
      notify_event "${not_msg}"
      ;;
    NOTBYPASS)
      notify_event "${not_msg}"
      ;;
    ECO)
      notify_event "${not_msg}"
      ;;
    NOTECO)
      notify_event "${not_msg}"
      ;;
    ALARM)
      notify_event "${not_msg}"
      ;;
    NOTALARM)
      notify_event "${not_msg}"
      ;;
    SUSPEND_STARTING)
      notify_event "${not_msg}"
      ;;
    SUSPEND_FINISHED)
      notify_event "${not_msg}"
      ;;
    *)
      warn "Unknown UPS event: ${not_type}"
      ;;
  esac
}

nut_timer() {
  local timer_name="${1}"
  local timer_args=""

  shift
  if [[ $# -gt 0 ]]; then
    local timer_args=("$@")
  fi

  logInfo "Handling UPS timer: ${timer_name} (${timer_args[@]})"

  case "${timer_name}" in
    earlyshutdown)
      warn "Triggering an early shutdown"
      if ! /usr/sbin/upsmon -c fsd; then
        error "Failed to call a forced shutdown"
      else
        logInfo "Forced shutdown called"
      fi
      ;;
    *)
      warn "Unknown UPS timer: ${timer_name}"
      ;;
  esac
}

nut_shutdown() {
  if ! "${UP_ROOT}/src/lifecycle/shutdown.sh" -e all; then
    error "Failed to cause a OS shutdown"
    return 1
  fi
  return 0
}

notify_event() {
  local not_type="${NOTIFYTYPE}"
  local not_ups="${UPSNAME}"
  local not_msg="${1}"

  # Subject
  UPS_SUB="[${HOSTNAME}] UPS - ${not_type} on ${not_ups}"
  
  # Prepare event message
  if [[ -z "${not_ups}" ]]; then
    UPS_MSG="An unknown UPS"
  else
    UPS_MSG="UPS ${not_ups}"
  fi

  if [[ -z "${not_type}" ]]; then
    UPS_MSG="${UPS_MSG} generated an unknown event"
  else
    UPS_MSG="${UPS_MSG} generated a ${not_type} event"
  fi
  
  if [[ -n "${not_msg}" ]]; then
    UPS_MSG=$(cat <<END
${UPS_MSG} with the following message:
${not_msg}
END
  )
  fi

  UPS_MSG=$(cat <<END
${UPS_MSG}

Subject: ${UPS_SUB}

Arguments to ${UP_ME}: (${#UP_ARGS[@]}):
$(for arg in "${UP_ARGS[@]}"; do echo "  ${arg}"; done)

NOTIFYTYPE: "${not_type}"
UPSNAME: "${not_ups}"
\$1: "${not_msg}"

List of UPS on this host:
$(/usr/bin/upsc -L)

$(for ups in $(/usr/bin/upsc -l); do
  echo "Data for UPS: ${ups}"
  echo ""
  /usr/bin/upsc ${ups}
  echo ""
  echo "Clients for UPS: ${ups}"
  /usr/bin/upsc -c ${ups}
  echo ""
done)
END
  )

  # Logging it
  logInfo <<END
Logging a UPS event:

${UPS_MSG}
END

  echo "${UPS_MSG}" | ${MAIL_CMD} -s "${UPS_SUB}" -r ${SENDER} ${SYSADMIN}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send UPS email"
  else
    logInfo "UPS email sent succesfully"
  fi

  # Send a XCP-ng notification
  xe message-create name="UPS Event" body="${UPS_SUB}" priority=$LVL_WARN host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send UPS notification to XCP-ng"
  else
    logInfo "UPS notification sent to XCP-ng"
  fi
}

nut_parse() {
  local short="h"
  local long="help"

  local opts
  opts=$(getopt --options ${short} --long ${long} --name "${UP_ME}" -- "${UP_ARGS[@]}")
  if [[ $? -ne 0 ]]; then
    error "Failed to parse arguments"
    return 1
  fi

  local cmd
  local cmd_args
  eval set -- "${opts}"
  while true; do
    case "$1" in
      -h|--help)
        nut_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      *)
        error "Invalid option: $1"
        nut_usage
        return 1
        ;;
    esac
  done

  # Handle positional arguments
  while [[ $# -gt 0 ]]; do
    if [[ -z ${cmd} ]]; then
      case "$1" in
        event|timer|shutdown)
          cmd="${1}"
          shift
          ;;
        *)
          error "Unknown command: ${1}"
          nut_usage
          return 1
          ;;
      esac
    elif [[ "${1}" != "--" ]]; then
      cmd_args=("$@")
      break
    else
      error "Unknown or too many argument: ${1}"
      return 1
    fi
  done

  if [[ -n "${cmd}" ]]; then
    case "${cmd}" in
      event)
        nut_event "${cmd_args[@]}"
        ;;
      timer)
        nut_timer "${cmd_args[@]}"
        ;;
      shutdown)
        nut_shutdown "${cmd_args[@]}"
        ;;
      *)
        error "Unknown command: ${cmd}"
        nut_usage
        return 1
        ;;
    esac
  else
    error "No command specified"
    nut_usage
    return 1
  fi

  return 0
}

nut_usage() {
  cat <<EOF
This script implements all the API calls and events generated by NUT (Network UPS Tools)
All the logic to handle UPS is here.

[ARGS] will contain the original arguments provided by NUT (See nut documentation)

Usage: ${UP_ME} [OPTIONS] COMMAND -- [ARGS]

Options:
  -h, --help    Display this help and exit

Commands:
  event         A UPS event was generated
  timer         A timer event was generated
  shutdown      Trigger a shutdown (from NUT)
EOF
}

info() {
  logInfo "$1"

  xe message-create name="nut_handler" body="$1" priority=${LVL_INFO} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

warn() {
  logWarn "$1"

  xe message-create name="nut_handler" body="$1" priority=${LVL_WARN} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

error() {
  logError "$1"

  xe message-create name="nut_handler" body="$1" priority=${LVL_ERROR} host-uuid=${HOST_ID}
  if [[ $? -ne 0 ]]; then
    logError "Failed to send notification to XCP-ng"
  fi
}

# Constants
SCHED_CMD="/usr/sbin/upssched"

# XCP-ng message levels
LVL_ERROR=1
LVL_WARN=2
LVL_INFO=3
LVL_DEBUG=4
LVL_TRACE=5

###########################
###### Startup logic ######
###########################
UP_ARGS=("$@")
UP_CWD=$(pwd)
UP_ME="$(basename "${BASH_SOURCE[0]}")"

# Get directory of this script
# https://stackoverflow.com/a/246128
UP_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${UP_SOURCE}" ]]; do # resolve $UP_SOURCE until the file is no longer a symlink
  UP_ROOT=$(cd -P "$(dirname "${UP_SOURCE}")" >/dev/null 2>&1 && pwd)
  UP_SOURCE=$(readlink "${UP_SOURCE}")
  [[ ${UP_SOURCE} != /* ]] && UP_SOURCE=${UP_ROOT}/${UP_SOURCE} # if $UP_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
UP_ROOT=$(cd -P "$(dirname "${UP_SOURCE}")" >/dev/null 2>&1 && pwd)
UP_ROOT=$(realpath "${UP_ROOT}/../..")

# Import dependencies
SETUP_REPO_DIR="${UP_ROOT}/external/setup"
if ! source "${SETUP_REPO_DIR}/external/slf4.sh/src/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
if ! source "${SETUP_REPO_DIR}/external/config.sh/src/config.sh"; then
  logFatal "Failed to import config.sh"
fi

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  logFatal "This script cannot be piped"
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  logFatal "This script cannot be sourced"
else
  # This script was executed
  nut_main
  exit $?
fi
