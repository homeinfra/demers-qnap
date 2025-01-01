# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# This script configures a deamon for startup and shutdown logic

enable_power_button() {
  local _logind_conf="/etc/systemd/logind.conf"
  local _current
  local _value
  local res

  if [[ -f "${_logind_conf}" ]]; then
    if ! _current=$(grep ".*HandlePowerKey=.*" "${_logind_conf}"); then
      logError "Expected to find HandlePowerKey in ${_logind_conf}"
      return 1
    else
      logDebug "Current line: ${_current}"
      _value="${_current#*=}"
      logInfo "Current value: ${_value}"
    fi
  else
    logError "Expected to find ${_logind_conf}"
    return 1
  fi

  # Validate there aren't any inhibitors configured
  if ! res=$(systemd-inhibit --list); then
    logError "Failed to list inhibitors"
    return 1
  elif [[ -n "${res}" ]]; then
    # Parse a string that should look like: 0 inhibitors listed.
    if [[ "${res}" == "0 inhibitors listed." ]]; then
      logInfo "No Inhibitors found"
    else
      logError <<EOF
Inhibitors found:
${res}
EOF
      return 1
    fi
  else
    logError "Expected some output from listing inhibitors"
    return 1
  fi

  # Being very careful, make sure we only edit the config in the two cases:
  # 1) It's commented out
  # 2) It's configured to ignore (Default value on XCP-ng)
  if echo "${_current}" | grep -q "^#.*HandlePowerKey=.*"; then
    logWarn "Power button is commented out. Unexpected but supported"
  elif ! echo "${_current}" | grep -q "^HandlePowerKey=.*"; then
    logError "Not commented and wrong key? Abort this unexpected result"
    return 1
  elif [[ "${_value}" == "ignore" ]]; then
    logInfo "Expected value when it's never been configured on XCP-ng"
  elif [[ "${_value}" == "poweroff" ]]; then
    logInfo "Power button is already configured to poweroff."
    return 0
  fi

  # We are about to re-configure. Check for the backup
  if [[ -f "${_logind_conf}.bak" ]]; then
    logWarn "Backup already exists. How did we get here?"
  else
    if ! cp "${_logind_conf}" "${_logind_conf}.bak"; then
      logError "Failed to backup ${_logind_conf}"
      return 1
    fi
    logInfo "Backup created for ${_logind_conf}"
  fi

  # Replace the line
  if ! sed -i 's/^.*HandlePowerKey=.*$/HandlePowerKey=poweroff/' "${_logind_conf}"; then
    logError "Failed to replace the line"
    return 1
  else
    logInfo "Power button configured to poweroff"
  fi

  # Restart logind service
  if ! systemctl restart systemd-logind; then
    logError "Failed to restart logind"
    return 1
  else
    logInfo "logind restarted"
  fi

  return 0
}

deamon_configure() {
  if [[ -z "${CONFIG_DIR}" ]]; then
    logError "CONFIG_DIR is not set"
    return 1
  fi

  local startup_script
  local shutdown_script
  startup_script="${DM_ROOT}/src/lifecycle/startup"
  shutdown_script="${DM_ROOT}/src/lifecycle/shutdown"

  # Create the service
  local service_file_src
  local service_file_ist
  service_file_src="${DM_ROOT}/data/qnap_lifecycle.service"
  service_file_ist="/etc/systemd/system/$(basename "${service_file_src}")"

  # Prepare service file
  local _content
  _content=$(cat "${service_file_src}")
  _content="${_content//"@STARTUP_CMD@"/${startup_script}}"
  _content="${_content//"@SHUTDOWN_CMD@"/${shutdown_script}}"
  _content="${_content//"@GIT_ROOT@"/${DM_ROOT}}"

  # Compare with existing service file
  local state
  if [[ -f "${service_file_ist}" ]]; then
    local _existing
    _existing=$(cat "${service_file_ist}")
    if [[ "${_content}" == "${_existing}" ]]; then
      logInfo "Service already configured"
      state="ok"
    else
      logWarn "Service configuration diverged. Replacing..."
      if ! rm -f "${service_file_ist}"; then
        logError "Failed to remove the existing service"
        return 1
      fi
      if ! echo "${_content}" >"${service_file_ist}"; then
        logError "Failed to configure the service"
        return 1
      else
        logInfo "Service reconfigured"
      fi
    fi
  else
    if ! echo "${_content}" >"${service_file_ist}"; then
      logError "Failed to configure the service"
      return 1
    else
      logInfo "Service configured"
    fi
  fi

  if [[ "${state}" != "ok" ]]; then
    if ! systemctl daemon-reload; then
      logError "Failed to reload the daemon"
      return 1
    else
      logDebug "systemd daemon reloaded"
    fi
  fi

  # Make sure the service is enabled
  if ! systemctl is-enabled --quiet "$(basename "${service_file_ist}")"; then
    if ! systemctl enable "$(basename "${service_file_ist}")"; then
      logError "Failed to enable the service"
      return 1
    else
      logInfo "Service enabled"
    fi
  else
    logInfo "Service already enabled"
  fi

  # Make sure the service is started
  if ! systemctl is-active --quiet "$(basename "${service_file_ist}")"; then
    if ! systemctl start "$(basename "${service_file_ist}")"; then
      logError "Failed to start the service"
      return 1
    else
      logInfo "Service started"
    fi
  else
    logInfo "Service already started"
  fi
}

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
DM_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${DM_SOURCE}" ]]; do # resolve $DM_SOURCE until the file is no longer a symlink
  DM_ROOT=$(cd -P "$(dirname "${DM_SOURCE}")" >/dev/null 2>&1 && pwd)
  DM_SOURCE=$(readlink "${DM_SOURCE}")
  [[ ${DM_SOURCE} != /* ]] && DM_SOURCE=${DM_ROOT}/${DM_SOURCE} # if $DM_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DM_ROOT=$(cd -P "$(dirname "${DM_SOURCE}")" >/dev/null 2>&1 && pwd)
DM_ROOT=$(realpath "${DM_ROOT}/../..")

# Import dependencies
# shellcheck disable=SC1091
if ! source "${PREFIX:-/usr/local}/lib/slf4.sh"; then
  echo "Failed to import slf4.sh"
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
