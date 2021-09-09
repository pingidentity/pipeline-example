#!/usr/bin/env sh

test -z "${REF}" && REF=$(git rev-parse --abbrev-ref HEAD)
set -a
# shellcheck source=@localSecrets
test -f ./ci_tools/@localSecrets && . ./ci_tools/@localSecrets

## CI VARIABLES
case "${REF}" in
  prod ) 
    RELEASE=${RELEASE:=prod}
    K8S_NAMESPACE="cicd-prod"
    ;;
  * )
    RELEASE="${REF}"
    K8S_NAMESPACE="cicd-dev" 
    ;;
esac

PROFILES_REPO_URL="https://github.com/pingidentity/pingidentity-devops-reference-pipeline.git"
VAULT_AUTH_ROLE="ping-dev-aws-us-east-2"
CHART_VERSION="0.7.5"
K8S_DIR=k8s
MANIFEST_DIR="${K8S_DIR}/manifests"
K8S_CLUSTER=${K8S_CLUSTER:-us}
K8S_SECRETS_DIR="${MANIFEST_DIR}/${K8S_CLUSTER}/${K8S_NAMESPACE}/secrets"
CURRENT_SHA=$(git log -n 1 --pretty=format:%h)


kubectl config use-context "${K8S_CLUSTER}"
kubectl config set-context --current --namespace="${K8S_NAMESPACE}"

getGlobalVars() {
  kubectl get cm "${RELEASE}-global-env-vars" -o=jsonpath='{.data}' -n "${K8S_NAMESPACE}" | jq -r '. | to_entries | .[] | .key + "=" + .value + ""'
}

getPfVars() {
export PF_ADMIN_PUBLIC_HOSTNAME=$(kubectl get ing -l app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=pingfederate-admin -o=jsonpath='{.items[0].spec.rules[0].host}')
PING_IDENTITY_PASSWORD="2FederateM0re"
}

createGlobalVarsPostman() {
  # kubectl get cm "${RELEASE}-global-env-vars" -o=jsonpath='{.data}' -n "${K8S_NAMESPACE}" | jq -r '. | to_entries | .[] | .key + "=" + .value + ""'
  data=$(kubectl get cm "${RELEASE}-global-env-vars" -n "${K8S_NAMESPACE}" -o=jsonpath='{.data}')
  keys=$(echo "$data" | jq -r '. | to_entries | .[] | .key')
  varEntries=""
  for key in $keys ; do
    value=$(echo "${data}" | jq -r ".${key}" )
    varEntries="${varEntries} { \"key\": \"${key}\", \"value\": \"${value}\" },"
  done
  varEntries=${varEntries%?}
  cat << EOF | kubectl apply -f -
  apiVersion: v1
  data:
    global_postman_vars.json: |
      {
        "id": "eae83fc1-25de-4def-9062-7dc2ba993710",
        "name": "myping",
        "values": [
          ${varEntries}
        ],
        "_postman_variable_scope": "global"
      }
  kind: ConfigMap
  metadata:
    annotations:
      use-subpath: "true"
    name: ${RELEASE}-global-env-vars-postman
    namespace: ${K8S_NAMESPACE}
EOF
}

getPfClientAppInfo(){
  # get bearer token (login). 
  p1Token=$(curl -sS --location -u "${PF_ADMIN_WORKER_ID}:${PF_ADMIN_WORKER_SECRET}" --request POST "https://auth.pingone.com/${P1_ADMIN_ENV_ID}/as/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' | jq -r ".access_token")
  # get client app and secret
  pfEnvClientId=$(curl -sS --location --request GET "https://api.pingone.com/v1/environments/${P1_ADMIN_ENV_ID}/applications" \
    --header "Authorization: Bearer ${p1Token}" \
    | jq -r "._embedded.applications[] | select(.name==\"${RELEASE}-pf-admin\") | .id")
  pfEnvClientSecret=$(curl -sS --location --request GET "https://api.pingone.com/v1/environments/${P1_ADMIN_ENV_ID}/applications/${pfEnvClientId}/secret" \
    --header "Authorization: Bearer ${p1Token}" \
    | jq -r '.secret')
}

getEnvKeys() {
    env | cut -d'=' -f1 | sed -e 's/^/$/'
}

expandFiles() {
    #
    # First, let's process all files that end in .subst
    #
    echo $*
    _expandPath="${1}"
    echo "  Processing templates"

    find "${_expandPath}" -type f -iname "subst.*" > tmpFileList
    while IFS= read -r template; do
        echo "    t - ${template}"
        _templateDir="$(dirname ${template})"
        _templateBase="$(basename ${template})"
        envsubst "'$(getEnvKeys)'" < "${template}" > "${_templateDir}/${_templateBase#subst.}"
    done < tmpFileList
    rm tmpFileList
}

applyManifests() {
  folders=${*}
  for folder in $folders ; do
    if test $folder != "--dry-run" ; then
      find "${folder}" -type f ! -name "*subst*" >> k8stmp
      while IFS= read -r k8sFile; do
        kubectl apply -f "$k8sFile" $_dryRun -o yaml
      done < k8stmp
      rm k8stmp
    fi
  done
}