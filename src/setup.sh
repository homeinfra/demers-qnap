#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script is used to configure the qnap machine
#
# Currently tested on XCP-ng 8.3 (CentOS)

AGE_KEY="homeinfra_demers"

setup() {
  declare -g DQ_ARGS=("$@")
  logInfo "Setup called with: ${DQ_ARGS[@]}"

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

###########################
###### Startup logic ######
###########################

DQ_ARGS=("$@")
DQ_CWD=$(pwd)
DQ_ME="$(basename "$0")"

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
source ${DQ_ROOT}/external/setup/src/slf4sh.sh
source ${DQ_ROOT}/external/setup/src/git.sh
source ${DQ_ROOT}/external/setup/src/sops.sh
source ${DQ_ROOT}/external/setup/src/age.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  setup "${@}"
  exit $?
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  echo "ERROR: This script cannot be sourced"
  exit 1
else
  # This script was executed
  setup "${@}"
  exit $?
fi
