#!/usr/bin/env bash
set -Eeuo pipefail

GIT_URL="${GIT_URL:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
DEV_NS="${DEV_NS:-mqtt-demo-dev}"
TEST_NS="${TEST_NS:-mqtt-demo-test}"
PROD_NS="${PROD_NS:-mqtt-demo-prod}"
CICD_NS="${CICD_NS:-mqtt-demo-cicd}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
ARGO_CONTROLLER_SA="${ARGO_CONTROLLER_SA:-openshift-gitops-argocd-application-controller}"
INSTALL_TEKTON_RESOURCES="${INSTALL_TEKTON_RESOURCES:-true}"

log(){ printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

apply_path() {
  local ns="${1:-}"
  local path="$2"
  [[ -e "$path" ]] || { warn "Path not found, skipping: $path"; return 0; }

  if [[ -d "$path" ]]; then
    if [[ -f "$path/kustomization.yaml" || -f "$path/kustomization.yml" || -f "$path/Kustomization" ]]; then
      log "Applying kustomize path $path ${ns:+into namespace $ns}"
      if [[ -n "$ns" ]]; then
        oc apply -n "$ns" -k "$path"
      else
        oc apply -k "$path"
      fi
    else
      log "Applying manifest path $path ${ns:+into namespace $ns}"
      if [[ -n "$ns" ]]; then
        oc apply -n "$ns" -f "$path"
      else
        oc apply -f "$path"
      fi
    fi
  else
    log "Applying file $path ${ns:+into namespace $ns}"
    if [[ -n "$ns" ]]; then
      oc apply -n "$ns" -f "$path"
    else
      oc apply -f "$path"
    fi
  fi
}

replace_repo_url() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  grep -RIl "https://github.com/your-org/ocp-mqtt-demo.git" "$target" 2>/dev/null | while read -r file; do
    sed -i "s#https://github.com/your-org/ocp-mqtt-demo.git#${GIT_URL}#g" "$file"
  done
}

patch_namespace_references() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  grep -RIl "mqtt-demo-dev\|mqtt-demo-test\|mqtt-demo-prod\|mqtt-demo-cicd" "$target" 2>/dev/null | while read -r file; do
    sed -i "s#mqtt-demo-dev#${DEV_NS}#g; s#mqtt-demo-test#${TEST_NS}#g; s#mqtt-demo-prod#${PROD_NS}#g; s#mqtt-demo-cicd#${CICD_NS}#g" "$file"
  done
}

ensure_project() {
  local ns="$1"
  if oc get namespace "$ns" >/dev/null 2>&1; then
    log "Project already exists: $ns"
  else
    log "Creating project: $ns"
    oc new-project "$ns" >/dev/null
  fi
}

wait_for_crd() { oc get crd "$1" >/dev/null 2>&1 || die "Required CRD missing: $1"; }

label_gitops_namespace_management() {
  local ns="$1"
  log "Labeling namespace $ns for OpenShift GitOps management"
  oc label namespace "$ns" argocd.argoproj.io/managed-by="$ARGO_NS" --overwrite >/dev/null
}

ensure_argocd_admin_rolebinding() {
  local ns="$1"
  log "Ensuring Argo CD controller has admin in $ns"
  cat <<EOF_RB | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-admin
  namespace: ${ns}
subjects:
- kind: ServiceAccount
  name: ${ARGO_CONTROLLER_SA}
  namespace: ${ARGO_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
EOF_RB
}

ensure_argocd_limitrange_role() {
  local ns="$1"
  log "Ensuring Argo CD controller has explicit LimitRange permissions in $ns"
  cat <<EOF_LR | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-limitrange-manager
  namespace: ${ns}
rules:
- apiGroups: [""]
  resources: ["limitranges"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-limitrange-manager
  namespace: ${ns}
subjects:
- kind: ServiceAccount
  name: ${ARGO_CONTROLLER_SA}
  namespace: ${ARGO_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: argocd-limitrange-manager
EOF_LR
}

setup_argocd_namespace_access() {
  local ns="$1"
  label_gitops_namespace_management "$ns"
  ensure_argocd_admin_rolebinding "$ns"
  ensure_argocd_limitrange_role "$ns"
}

need_cmd oc
need_cmd grep
need_cmd sed
[[ -n "$GIT_URL" ]] || die "Set GIT_URL, for example: export GIT_URL=https://github.com/YOUR_ORG/ocp-mqtt-demo.git"
[[ -d deploy ]] || die "Run this from the repo root. ./deploy is missing."
oc whoami >/dev/null 2>&1 || die "You are not logged in to OpenShift."
wait_for_crd applications.argoproj.io
wait_for_crd scaledjobs.keda.sh

ensure_project "$DEV_NS"
ensure_project "$TEST_NS"
ensure_project "$PROD_NS"
setup_argocd_namespace_access "$DEV_NS"
setup_argocd_namespace_access "$TEST_NS"
setup_argocd_namespace_access "$PROD_NS"

replace_repo_url deploy
patch_namespace_references deploy
apply_path "" deploy/applications

if [[ "$INSTALL_TEKTON_RESOURCES" == "true" ]]; then
  if oc get crd pipelines.tekton.dev >/dev/null 2>&1; then
    ensure_project "$CICD_NS"
    apply_path "$CICD_NS" deploy/tekton
  else
    warn "Tekton CRDs not found. Skipping deploy/tekton installation."
  fi
fi

cat <<EOF2

Bootstrap complete.

Useful commands:
  oc get applications -n ${ARGO_NS}
  oc get all -n ${DEV_NS}
  oc get route frontend -n ${DEV_NS}
  oc get scaledjob -n ${DEV_NS}
  oc get pipeline,task,pipelinerun -n ${CICD_NS}
EOF2
