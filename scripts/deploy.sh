#!/usr/bin/env sh
CWD=$(dirname "$0")

usage ()
{
cat <<END_USAGE
Usage:  {options} 
    * - required
    where {options} include:
    --verbose|-v
        Use verbose output
    --dry-run|-d
        Show deployment yamls without appying
END_USAGE
exit 99
}
exit_usage()
{
    echo "${RED}$*${NC}"
    usage
    exit 1
}
while ! test -z ${1} ; do
  case "${1}" in
    --dry-run|-d)
      export _dryRun="--dry-run" ;;
    --verbose|-v)
      set -x ;;
    -h|--help)
      exit_usage "./scripts/deploy.sh --dry-run";;
    *)
      exit_usage "Unrecognized Option ${1}" ;;
  esac
  shift
done

# Source global functions and variables
. "${CWD}/vars.sh"
. "${CWD}/functions.sh"
getLocalSecrets
getEnv
getNamespace

# Validate Pre-reqs
_missingTool="false"
for _tool in kubectl helm base64 envsubst jq;  do
  if ! type $_tool >/dev/null 2>&1 ; then
    echo "${RED}$_tool not found${NC}"
    _missingTool="true"
  fi
done
helm plugin list | grep diff
test ${?} -ne 0 && echo "${RED}helm diff plugin not found${NC}" && _missingTool="true"
test $_missingTool = "true" && exit_usage "Missing tool(s)"

# Builds sha for each product based on the folder name in ./profiles/* (e.g. pingfederate_SHA)
# Any change in this SHA value (i.e., code is updated in some way) determines what will be rolled in the environment
for D in ./profiles/* ; do
  if [ -d "${D}" ]; then
    _prodName=$(basename "${D}" | sed 's/-/_/' | tr '[:lower:]' '[:upper:]')
    dirr="${D}"
    set -a
    eval "${_prodName}_SHA=sha-$(git log -n 1 --pretty=format:%h -- "$dirr")"
    set +a
  fi
done

# Convert .subst files to hardcoded files for deployment
envsubstFiles "helm" "manifest"

# START: Deploy

## Apply all evaluated kubernetes manifest files
find "manifest" -type f -regex ".*final$" > k8stmp
while IFS= read -r k8sFile; do
  kubectl apply -f "$k8sFile" -n "${K8S_NAMESPACE}" $_dryRun
done < k8stmp
test -z "${_dryRun}" && rm k8stmp

## Identify possible values.yaml files
VALUES_FILE=${VALUES_FILE:=helm/values.yaml.final}
VALUES_DEV_FILE=${VALUES_DEV_FILE:=helm/values.dev.yaml.final}
test "${ENV}" != "prod" && _valuesDevFile="-f ${VALUES_DEV_FILE}"

## Helm Deploy
echo "${GREEN}INFO: Running Helm upgrade${NC}"

_deployUTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

helm upgrade --install \
  "${ENV}" pingidentity/ping-devops \
  -f "${VALUES_FILE}" ${_valuesDevFile}  \
  --version "${CHART_VERSION}" -n "${K8S_NAMESPACE}" $_dryRun

## For Statefulsets that failed previously, the crashing pod must be deleted to pick up new changes
##    this is per: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#forced-rollback
##
## Capture and delete pods that:
##  - Are part of a StatefulSet
##  - Are not ready
##  - Have restarted more than twice
_crashingPods=$(kubectl get pods -l app.kubernetes.io/instance="${ENV}" -n "${K8S_NAMESPACE}" -o go-template='{{range $index, $element := .items}}{{range $element.metadata.ownerReferences}}{{if eq .kind "StatefulSet"}}{{range $element.status.containerStatuses}}{{if and (gt .restartCount 2) (not .ready) }}{{$element.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}{{end}}')
test ! -z "${_crashingPods}" \
  && kubectl delete pod $(printf "%s " $_crashingPods) --force --grace-period=0 -n "${K8S_NAMESPACE}" "${_dryRun}"

# Finish by cleaning up hardcoded files if not a dry-run
test -z "${_dryRun}" && cleanExpandedFiles

# END: Deploy

# START: Watch Deployment Health

if test -z $_dryRun ; then 
  ## Set to maximum time for a successful deploy
  _timeout=3600
  _timeoutElapsed=0
  _readyCount=0

  ## Collect previous helm release info to show in case of failure
  test ! -d tmp && mkdir tmp
  revCurrent=$(helm ls --filter "${ENV}" -o json -n "${K8S_NAMESPACE}"| jq -r '.[0].revision')
  revPrevious=$(( revCurrent - 1 ))
  helm diff revision "${ENV}" $revPrevious $revCurrent -n "${K8S_NAMESPACE}" --no-color -C 0 > tmp/helmdiff.txt

  ## Watch helm release for pods going to crashloop
  echo "${YELLOW}INFO: Watching Release, DO NOT STOP SCRIPT${NC}"
  while test ${_timeoutElapsed} -lt ${_timeout} ; do
    sleep 6
    ## watch pods that are only part of this release upgrade:
    # kubectl get pods -l app.kubernetes.io/instance="${ENV}" -o go-template='{{range $index, $element := .items}}{{range .status.containerStatuses}}{{if not .ready}}{{$element.metadata.name}} {{$element.metadata.creationTimestamp}}{{"\n"}}{{end}}{{end}}{{end}}'

    if test $(kubectl get pods -l app.kubernetes.io/instance="${ENV}" -n "${K8S_NAMESPACE}" -o go-template='{{range $index, $element := .items}}{{range .status.containerStatuses}}{{if not .ready}}{{$element.metadata.name}} {{$element.metadata.creationTimestamp}}{{"\n"}}{{end}}{{end}}{{end}}' | awk '{if ($2 >= "'$(echo "$_deployUTC")'") { print $1 }}' | wc -l ) = 0 ; then
      _readyCount=$(( _readyCount+1 ))
      sleep 4
    else 
      ## _crashingPods are pods that are:
      ##  - Started after this helm upgrade
      ##  - not ready
      ##  - and have more than 2 restarts
      _crashingPods=$(kubectl get pods -l app.kubernetes.io/instance="${ENV}" -n "${K8S_NAMESPACE}" -o go-template='{{range $index, $element := .items}}{{range .status.containerStatuses}}{{if and (gt .restartCount 2) (not .ready) }}{{$element.metadata.name}} {{$element.metadata.creationTimestamp}}{{"\n"}}{{end}}{{end}}{{end}}' | awk '{if ($2 >= "'$(echo "$_deployUTC")'") { print $1 }}')
      _numCrashing=$(printf "${_crashingPods}" | wc -c)
      ## Recognize failed release via extended crashloop
      if test $_numCrashing -ne 0 ; then
        echo "${RED}ERROR: Found pods crashing:'${NC}"
        echo "${RED}$_crashingPods${NC}"
        _timeoutElapsed=$(( _timeout+1 ))
      fi
    fi
    if test ${_readyCount} -ge 3 ; then
      echo "${GREEN}INFO: Successfully Deployed.${NC}"
      exit 0
    fi
    _timeoutElapsed=$((_timeoutElapsed+6))
  done

  ## Getting this far is an error
  ##   show what changed to help identify errors
  if test ${_timeoutElapsed} -ge ${_timeout} ; then

    cat tmp/helmdiff.txt
    echo "${RED}ERROR: Unsuccessful Deployment${NC}"
    echo "${RED}ERROR: Crashing Pods: $_crashingPods${NC}"
    exit 1
  fi
fi