#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script is used to configure the qnap machine
#
# Currently tested on XCP-ng 8.3 (CentOS)

setup() {
  declare -g DQ_ARGS=("$@")
  echo "Setup called with: ${DQ_ARGS[@]}"
}

###########################
###### Startup logic ######
###########################

if [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  export -f setup
else
  setup "${@}"
  exit $?
fi