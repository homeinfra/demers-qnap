#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Utility functions for XenAPI usage

# Parse a list of parameters
#
# Parameters:
#   $1[in]: Response received from a command
# Returns:
#   0: If successfully parsed
xe_parse_params() {
  local _response="$1"
  
  # clear the associative array
  declare -gA array

  while IFS= read -r line; do
    # Remove leading and trailing whitespace
    line=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')

    # Skip empty lines
    if [[ -z "$line" ]]; then
        continue
    fi

    # Split the line into key and value
    key=$(echo "$line" | cut -d ':' -f 1 | sed 's/[ \t]*$//')
    value=$(echo "$line" | cut -d ':' -f 2- | sed 's/^[ \t]*//')

    # Make sure key and value are not empty
    if [[ -z "$key" ]] || [[ -z "$value" ]]; then
      logWarn "Skipping invalid line: $line"
      continue
    fi

    # Remove " ( RO)" from the key if present
    key=$(echo "$key" | sed 's/ \(.*\)//')

    # Store in the associative array
    array["${key}"]="${value}"

  done <<< "${_response}"

  return 0
}

# Stringify the array variable so it can be used in other inputs
#
# Parameters:
#   $1[out]: Resulting string
stringify_array() {
  local _result="$1"
  
  local key
  local result=""
  for key in "${!array[@]}"; do
    result="${result}\n${key}=${array[$key]}"
  done
  eval "$_result='$result'"
}

# Stores array responses (See function xe_parse_params)
declare -A array

# Store login parameters (Used when working remotely)
declare -g XE_LOGIN

###########################
###### Startup logic ######
###########################

XE_ARGS=("$@")
XE_CWD=$(pwd)
XE_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
XE_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${XE_SOURCE}" ]]; do # resolve $XE_SOURCE until the file is no longer a symlink
  XE_ROOT=$(cd -P "$(dirname "${XE_SOURCE}")" >/dev/null 2>&1 && pwd)
  XE_SOURCE=$(readlink "${XE_SOURCE}")
  [[ ${XE_SOURCE} != /* ]] && XE_SOURCE=${XE_ROOT}/${XE_SOURCE} # if $XE_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
XE_ROOT=$(cd -P "$(dirname "${XE_SOURCE}")" >/dev/null 2>&1 && pwd)
XE_ROOT=$(realpath "${XE_ROOT}/..")

# Import dependencies
source ${XE_ROOT}/../../external/setup/src/slf4sh.sh

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