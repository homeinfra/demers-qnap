#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# SSH confiuration to be invoked at startup
# (This file was automatically generated)

# Make sure the ssh agent is running
if [[ -z "${SSH_AUTH_SOCK}" ]]; then
  eval "$(ssh-agent -s)"
fi

# Below are keys to be supported
ssh-add /root/.ssh/github_jeremfg
