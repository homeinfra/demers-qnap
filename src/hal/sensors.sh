# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# This script is used to configure the qnap sensors

if [[ -z ${GUARD_SENSORS_SH} ]]; then
  GUARD_SENSORS_SH=1
else
  return 0
fi

sensor_install() {
  # Make sure we have the right packages
  if ! pkg_install "lm_sensors" "coretemp-module-alt"; then
    logError "Failed to install lm_sensors"
    return 1
  fi

  if ! sensor_detect; then
    logError "Failed to detect sensors"
    return 1
  fi
}

sensor_detect() {
  if [[ ! -f "/etc/sysconfig/lm_sensors" ]]; then
    logWarn "Cannot find lm_sensors configuration file. Assuming detection was not performed"
  else
    # Check if file contains our expeced sensor modules
    if [[ -z "${HW_SENSORS}" ]]; then
      logError "HW_SENSORS is not set"
      return 1
    fi

    local not_found=0
    local module
    for module in ${HW_SENSORS}; do
      if ! grep -q "${module}" "/etc/sysconfig/lm_sensors"; then
        not_found=1
        logWarn "Sensor module ${module} not found. Assuming sensor detection was not performed."
      fi
    done

    if [[ ${not_found} -eq 0 ]]; then
      logInfo "Sensors were already detected"
      return 0
    fi
  fi

  # If we reach here, we need to perform sensor detection
  if ! sensors-detect --auto; then
    logError "Failed to detect sensors"
    return 1
  fi
}

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
SE_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${SE_SOURCE}" ]]; do # resolve $SE_SOURCE until the file is no longer a symlink
  SE_ROOT=$(cd -P "$(dirname "${SE_SOURCE}")" >/dev/null 2>&1 && pwd)
  SE_SOURCE=$(readlink "${SE_SOURCE}")
  [[ ${SE_SOURCE} != /* ]] && SE_SOURCE=${SE_ROOT}/${SE_SOURCE} # if $SE_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SE_ROOT=$(cd -P "$(dirname "${SE_SOURCE}")" >/dev/null 2>&1 && pwd)
SE_ROOT=$(realpath "${SE_ROOT}/../..")

# Determine BPKG's global prefix
if [[ -z "${PREFIX}" ]]; then
  if [[ $(id -u || true) -eq 0 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="${HOME}/.local"
  fi
fi

# Import dependencies
SETUP_REPO_DIR="${SE_ROOT}/external/setup"
# shellcheck disable=SC1091
if ! source "${PREFIX}/lib/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
# shellcheck disable=SC1091
if ! source "${SETUP_REPO_DIR}/src/pkg.sh"; then
  logFatal "Failed to import pkg.sh"
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
