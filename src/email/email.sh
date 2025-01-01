# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# This script configures email notifications on XCP-ng

if [[ -z ${GUARD_QN_EMAIL_SH} ]]; then
  GUARD_QN_EMAIL_SH=1
else
  return 0
fi

email_install() {
  local client_config_src="${EM_ROOT}/data/email.env"
  local mta_config_src="${EM_ROOT}/data/gmail.env"

  local email_setup_script="${SETUP_REPO_DIR}/src/mail"
  if [[ ! -f "${email_setup_script}" ]]; then
    logError "Email setup script not found"
    return 1
  fi
  if ! BIN_DIR=${BIN_DIR} CONFIG_DIR=${CONFIG_DIR} "${email_setup_script}" configure "${client_config_src}" "${mta_config_src}"; then
    logError "Failed to configure email"
    return 1
  fi

  # Configure XCP-ng
  if ! xe_configure_email "${client_config_src}"; then
    logError "Failed to configure email"
    return 1
  else
    logInfo "Configured XCP-ng's email notifications"
  fi

  return 0
}

# Variables loaded externally
BIN_DIR=""
CONFIG_DIR=""

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
EM_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${EM_SOURCE}" ]]; do # resolve $EM_SOURCE until the file is no longer a symlink
  EM_ROOT=$(cd -P "$(dirname "${EM_SOURCE}")" >/dev/null 2>&1 && pwd)
  EM_SOURCE=$(readlink "${EM_SOURCE}")
  [[ ${EM_SOURCE} != /* ]] && EM_SOURCE=${EM_ROOT}/${EM_SOURCE} # if $EM_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
EM_ROOT=$(cd -P "$(dirname "${EM_SOURCE}")" >/dev/null 2>&1 && pwd)
EM_ROOT=$(realpath "${EM_ROOT}/../..")

# Import dependencies
SETUP_REPO_DIR="${EM_ROOT}/external/setup"
XE_LIB_DIR="${EM_ROOT}/external/xapi.sh"
# shellcheck disable=SC1091
if ! source "${PREFIX:-/usr/local}/lib/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
# shellcheck disable=SC1091
if ! source "${XE_LIB_DIR}/src/xe_host.sh"; then
  logFatal "Failed to import xe_host.sh"
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
