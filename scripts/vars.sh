#!/usr/bin/env sh

# Set all Global script variables
#   Every variable in this env should be exported

# INTERNAL SCRIPT VARS - COMMENTED DOCS - DO NOT MODIFY
#   These vars can be used in profiles, values.yamls, or manifest files as desired. 
## ENV:
##   For dev envs - concat of ENV_PREFIX and branch name
##   For prod - concat of 'prod' and branch name
##
## SERVER_PROFILE_BRANCH - git branch that pipeline corresponds to.
##    Good for SERVER_PROFILE_BRANCH variable in values.yaml
# END SCRIPT VARS


## Default branch of repo
export DEFAULT_BRANCH=prod
export HELM_CHART_NAME="pingidentity/ping-devops"
export HELM_CHART_URL="https://helm.pingidentity.com/"
export CHART_VERSION="0.9.0"
## Useful for multiple pipelines in same clusters
##  Prefixes ENV variable. ENV variable is used for helm release name.
##  If used, include trailing slash. (e.g. ENV_PREFIX="myenv-")
export ENV_PREFIX=""
