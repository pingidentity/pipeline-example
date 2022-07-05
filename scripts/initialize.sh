#!/usr/bin/env sh

CWD=$(dirname "$0")

# Source global functions and variables
. "${CWD}/vars.sh"
. "${CWD}/functions.sh"

usage ()
{
cat <<END_USAGE
Usage:  ./scripts/initialize.sh
END_USAGE
exit 99
}
exit_usage()
{
    echo "${RED}$*${NC}"
    usage
    exit 1
}

# Validate Pre-reqs
if test -f ~/.pingidentity/config ; then
  . "${HOME}/.pingidentity/config"
elif test -f ~/.pingidentity/devops ; then
  . "${HOME}/.pingidentity/devops"
elif ! env | grep PING_IDENTITY_DEVOPS_USER >/dev/null 2>&1 ; then
  read -p "Enter your Ping Identity DevOps user name:"
  export PING_IDENTITY_DEVOPS_USER="${REPLY}"
  read -p "Enter your Ping Identity DevOps key:"
  export PING_IDENTITY_DEVOPS_KEY="${REPLY}"
fi

_missingTool="false"
for _tool in gh kubectl helm base64;  do
  if ! type $_tool >/dev/null 2>&1 ; then
    echo "${RED}$_tool not found${NC}"
    _missingTool="true"
  fi
done
test $_missingTool = "true" && exit_usage "Missing tool(s)"


# Define Functions
_generateKubeconfig() {

_currentNamespace=$(kubectl config view --minify -o jsonpath='{..namespace}')
echo "Use separate K8s namespace per environment? (**Requires cluster admin access**)"
read -p "y/n - Default (n):"
if test "${REPLY}" = "y" ; then
  _k8sNamespace='default'
  echo "Creating ping-devops-admin serviceaccount in ${_k8sNamespace}"
  echo "" >> "${CWD}/vars.sh"
  echo 'export NS_PER_ENV="true"' >> "${CWD}/vars.sh"
  git add "${CWD}/vars.sh" >/dev/null 2>&1
  git commit -m "1:1 K8sNamespace:Environment" >/dev/null 2>&1

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ping-devops-admin
  namespace: ${_k8sNamespace}
---
apiVersion: v1
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: ping-devops-cluster-admin
  rules:
  - apiGroups:
    - '*'
    resources:
    - '*'
    verbs:
    - '*'
kind: List
metadata:
  resourceVersion: ""
  selfLink: ""
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ping-devops-cluster-admin
roleRef:
  kind: ClusterRole
  name: ping-devops-cluster-admin
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: ping-devops-admin
  namespace: ${_k8sNamespace}
EOF
else
  echo "Using one namespace for all environments.."
  read -p "Which Kubernetes namespace to use? (Enter for ${_currentNamespace})"
  _k8sNamespace="${REPLY:-${_currentNamespace}}"
  echo "Using Namespace: ${_k8sNamespace}"
  echo "Generating Kubeconfig: ${_k8sNamespace}.."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ping-devops-admin
  namespace: ${_k8sNamespace}
---
apiVersion: v1
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: namespace-admin
    namespace: ${_k8sNamespace}
  rules:
  - apiGroups:
    - '*'
    resources:
    - '*'
    verbs:
    - '*'
kind: List
metadata:
  resourceVersion: ""
  selfLink: ""
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: namespace-admin
roleRef:
  kind: Role
  name: namespace-admin
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: ping-devops-admin
EOF

fi

USER_TOKEN_NAME=$(kubectl -n ${_k8sNamespace} get serviceaccount ping-devops-admin -o=jsonpath='{.secrets[0].name}')
USER_TOKEN_VALUE=$(kubectl -n ${_k8sNamespace} get secret/${USER_TOKEN_NAME} -o=go-template='{{.data.token}}' | base64 --decode)
CURRENT_CONTEXT=$(kubectl config current-context)
CURRENT_CLUSTER=$(kubectl config view --raw -o=go-template='{{range .contexts}}{{if eq .name "'''${CURRENT_CONTEXT}'''"}}{{ index .context "cluster" }}{{end}}{{end}}')
CLUSTER_CA=$(kubectl config view --raw -o=go-template='{{range .clusters}}{{if eq .name "'''${CURRENT_CLUSTER}'''"}}"{{with index .cluster "certificate-authority-data" }}{{.}}{{end}}"{{ end }}{{ end }}')
CLUSTER_SERVER=$(kubectl config view --raw -o=go-template='{{range .clusters}}{{if eq .name "'''${CURRENT_CLUSTER}'''"}}{{ .cluster.server }}{{end}}{{ end }}')

cat << EOF > ${CWD}/@kubeconfig
apiVersion: v1
kind: Config
current-context: ${CURRENT_CONTEXT}
contexts:
- name: ${CURRENT_CONTEXT}
  context:
    cluster: ${CURRENT_CONTEXT}
    user: ping-devops-admin
    namespace: ${_k8sNamespace}
clusters:
- name: ${CURRENT_CONTEXT}
  cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: ${CLUSTER_SERVER}
users:
- name: ping-devops-admin
  user:
    token: ${USER_TOKEN_VALUE}
EOF

## create KUBECONFIG_YAML secret
base64 "${CWD}/@kubeconfig" | tr -cd "[:print:]" > "${CWD}/@kubeconfigb64"
gh secret set KUBECONFIG_YAML < "${CWD}/@kubeconfigb64"
rm "${CWD}/@kubeconfigb64"

echo "${YELLOW}To run scripts locally, run:  export KUBECONFIG=${CWD}/@kubeconfig${NC}"
}

_setDevopsSecret(){
  test -z ${PING_IDENTITY_DEVOPS_USER} && exit_usage "PING_IDENTITY_DEVOPS_USER not found in shell environment"
  PING_IDENTITY_DEVOPS_USER_BASE64=$(printf "${PING_IDENTITY_DEVOPS_USER}" | base64 | tr -d '\r?\n')
  PING_IDENTITY_DEVOPS_KEY_BASE64=$(printf ${PING_IDENTITY_DEVOPS_KEY} | base64 | tr -d '\r?\n')
  gh secret set PING_IDENTITY_DEVOPS_USER_BASE64 -b"${PING_IDENTITY_DEVOPS_USER_BASE64}"
  gh secret set PING_IDENTITY_DEVOPS_KEY_BASE64 -b"${PING_IDENTITY_DEVOPS_KEY_BASE64}"
  echo "PING_IDENTITY_DEVOPS_USER_BASE64=${PING_IDENTITY_DEVOPS_USER_BASE64}" >> "${CWD}/local-secrets.sh"
  echo "PING_IDENTITY_DEVOPS_KEY_BASE64=${PING_IDENTITY_DEVOPS_KEY_BASE64}" >> "${CWD}/local-secrets.sh"
}

# Determine if first initialization
if gh secret list | grep KUBECONFIG_YAML >/dev/null 2>&1 && test -f "${CWD}/@kubeconfig"; then
  echo "${YELLOW} Found previous initialization.
  To run locally, set: KUBECONFIG=${CWD}/@kubeconfig
  ${NC}"
  exit 0
fi

# Set all local and GH Secrets
echo "#!/usr/bin/env sh" > "${CWD}/local-secrets.sh"

read -p "Do you want to use Ping Identity Baseline demo profiles? (y/n)"
if test "${REPLY}" != "n"; then
  echo "${GREEN}INFO: Preparing Baseline${NC}"
  _pingProfilesDir="/tmp/ping-server-profiles"
  test -d "${_pingProfilesDir}" && rm -rf "${_pingProfilesDir}"
  git clone --branch "refcicd" https://github.com/pingidentity/pingidentity-server-profiles.git "${_pingProfilesDir}"  >/dev/null 2>&1
  test $? -ne 0 && exit_usage "Failed Clone"
  mkdir profiles
  cp -r ${_pingProfilesDir}/baseline/* profiles
  cd profiles || exit
  mv pingaccess pingaccess-engine
  mv pingfederate pingfederate-engine
  mkdir -p pingaccess-admin/instance pingfederate-admin/instance
  mv pingaccess-engine/instance/data pingaccess-admin/instance/data
  mv pingfederate-engine/instance/bulk-config pingfederate-admin/instance/bulk-config
  cp -r pingcentral/dev-unsecure/instance pingcentral
  rm -rf CONTRIBUTING.md DISCLAIMER LICENSE docker-compose.yaml pingdataconsole-8.3 pingdatagovernance-8.1.0.0 pingdatagovernance
  cd -  >/dev/null 2>&1 || exit
  git add profiles >/dev/null 2>&1
  git commit -m "Add Ping Identity Baseline" >/dev/null 2>&1
else
  mkdir profiles
  echo "${YELLOW} Be sure to fill out the profiles folder..${NC}"
fi

_setDevopsSecret
_generateKubeconfig

git push origin
echo "${GREEN} Initialization completed successfully.${NC}"