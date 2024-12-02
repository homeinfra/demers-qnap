#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# API for XCP-ng host configuration

# Get the current host
#
# Parameters:
#   $1[out]: ID of the host
# Returns:
#   0: If host was found
#   1: If host was not found
hs_current_host() {
  local _id="$1"

  # Check tool is available
  if ! command -v xe &>/dev/null; then
    echo "ERROR: xe tool not found"
    return 1
  fi

  local res
  if ! res=$(xe ${XE_LOGIN} host-list --minimal); then
    logError "Failed to get host"
    return 1
  elif [[ -z "${res}" ]]; then
    logError "Host not found"
    return 1
  else
    eval "$_id='${res}'"
    logInfo "Host: ${res} found"
    return 0
  fi
}

###########################
###### Startup logic ######
###########################

HS_ARGS=("$@")
HS_CWD=$(pwd)
HS_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
HS_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${HS_SOURCE}" ]]; do # resolve $HS_SOURCE until the file is no longer a symlink
  HS_ROOT=$(cd -P "$(dirname "${HS_SOURCE}")" >/dev/null 2>&1 && pwd)
  HS_SOURCE=$(readlink "${HS_SOURCE}")
  [[ ${HS_SOURCE} != /* ]] && HS_SOURCE=${HS_ROOT}/${HS_SOURCE} # if $HS_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
HS_ROOT=$(cd -P "$(dirname "${HS_SOURCE}")" >/dev/null 2>&1 && pwd)
HS_ROOT=$(realpath "${HS_ROOT}/..")

# Import dependencies
source ${HS_ROOT}/../../external/setup/src/slf4sh.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  echo "ERROR: This script cannot be piped"
  exit 1
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  # echo "ERROR: This script cannot be executed"
  # exit 1
  test
  exit $?
fi