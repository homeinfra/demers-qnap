#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script is used to configure the qnap sensors

if [[ -z ${GUARD_QN_SENSORS_SH} ]]; then
  GUARD_QN_SENSORS_SH=1
else
  return
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
    if [[ -z "${QN_SENSORS}" ]]; then
      logError "QN_SENSORS is not set"
      return 1
    fi

    local not_found=0
    local module
    for module in ${QN_SENSORS}; do
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

SE_ARGS=("$@")
SE_CWD=$(pwd)
SE_ME="$(basename "$0")"

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

# Import dependencies
source ${SE_ROOT}/external/setup/src/slf4sh.sh
source ${SE_ROOT}/external/setup/src/pkg.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  echo "ERROR: This script cannot be piped"
  exit 1
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  echo "ERROR: This script cannot be executed"
  exit 1
fi
