# Deployment and promotion guide

## Prerequisites

Install these operators first:

- OpenShift GitOps
- KEDA
- OpenShift Pipelines (for the Tekton promotion flow)

## Bootstrap

From the repo root:

```bash
chmod +x bootstrap.sh
export GIT_URL="https://github.com/YOUR_ORG/ocp-mqtt-demo.git"
export GIT_BRANCH="main"
./bootstrap.sh
```

## What bootstrap installs

Into the app namespaces:

- Argo CD namespace onboarding labels
- fallback Argo CD `admin` RoleBinding
- explicit `argocd-limitrange-manager` Role and RoleBinding
- Argo CD `Application` objects for `dev`, `test`, and `prod`

Into `mqtt-demo-cicd` if Tekton is present:

- `ServiceAccount/pipeline`
- `PersistentVolumeClaim/tekton-workspace`
- Tekton `Task` resources
- `Pipeline/promote-demo-release`
- example `PipelineRun` YAMLs

## Git credentials for Tekton push-back

The promotion pipeline commits and pushes back to Git, so the Tekton `pipeline` service account needs Git credentials.

Example for GitHub over HTTPS:

```bash
oc create secret generic git-credentials \
  -n mqtt-demo-cicd \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=YOUR_GIT_USERNAME \
  --from-literal=password=YOUR_GIT_TOKEN
```

Add the Tekton Git annotation so the secret is used for the Git host:

```bash
oc patch secret git-credentials -n mqtt-demo-cicd --type merge -p '{
  "metadata": {
    "annotations": {
      "tekton.dev/git-0": "https://github.com"
    }
  }
}'
```

Link it to the `pipeline` service account:

```bash
oc patch sa pipeline -n mqtt-demo-cicd --type merge -p '{
  "secrets": [{"name":"git-credentials"}]
}'
```

## Release metadata

Each environment has a `release.env` file.

Example:

```bash
deploy/overlays/dev/release.env
```

```dotenv
DEMO_ENV=dev
DEMO_RELEASE_ID=1.0.0-dev
PROMOTED_FROM=source
PROMOTED_AT=bootstrap
PROMOTED_BY=manual
```

The API reads that ConfigMap and the frontend displays the current environment and release.

## Promotion procedure

### Promote dev to test

```bash
tkn pipeline start promote-demo-release \
  -n mqtt-demo-cicd \
  -p git-url=https://github.com/YOUR_ORG/ocp-mqtt-demo.git \
  -p git-revision=main \
  -p source-environment=dev \
  -p target-environment=test \
  -p promoted-by="gavin" \
  -w name=shared-workspace,claimName=tekton-workspace
```

### Promote test to prod

```bash
tkn pipeline start promote-demo-release \
  -n mqtt-demo-cicd \
  -p git-url=https://github.com/YOUR_ORG/ocp-mqtt-demo.git \
  -p git-revision=main \
  -p source-environment=test \
  -p target-environment=prod \
  -p promoted-by="gavin" \
  -w name=shared-workspace,claimName=tekton-workspace
```

### Override the release ID explicitly

By default, the pipeline copies the release ID from the source environment. You can override it:

```bash
tkn pipeline start promote-demo-release \
  -n mqtt-demo-cicd \
  -p git-url=https://github.com/YOUR_ORG/ocp-mqtt-demo.git \
  -p git-revision=main \
  -p source-environment=dev \
  -p target-environment=test \
  -p release-id=1.0.1 \
  -p promoted-by="gavin" \
  -w name=shared-workspace,claimName=tekton-workspace
```

## What the Tekton pipeline does

1. clones the repo
2. validates the source overlay with `kubectl kustomize`
3. updates `deploy/overlays/<target>/release.env`
4. validates the target overlay with `kubectl kustomize`
5. commits and pushes the change
6. Argo CD syncs the target environment from Git

## Validation

Check GitOps:

```bash
oc get applications -n openshift-gitops
oc get all -n mqtt-demo-dev
oc get all -n mqtt-demo-test
oc get all -n mqtt-demo-prod
```

Check Tekton:

```bash
oc get task,pipeline,pipelinerun -n mqtt-demo-cicd
```

Watch a promotion run:

```bash
tkn pipelinerun list -n mqtt-demo-cicd
tkn pipelinerun logs -n mqtt-demo-cicd -L -f
```

Check the promoted release in the UI:

- open the frontend route in `test` or `prod`
- verify the environment and release banner changed after the promotion commit synced

## Files you will edit most often

For worker speed and queue behavior:

```bash
deploy/base/keda.yaml
```

For release tracking:

```bash
deploy/overlays/dev/release.env
deploy/overlays/test/release.env
deploy/overlays/prod/release.env
```

For Tekton promotion logic:

```bash
deploy/tekton/10-task-git-clone.yaml
deploy/tekton/20-task-validate-overlay.yaml
deploy/tekton/30-task-update-release.yaml
deploy/tekton/40-task-commit-push.yaml
deploy/tekton/50-pipeline-promotion.yaml
```

## Troubleshooting

### Tekton pipeline cannot push to Git

Check the `git-credentials` secret and the `tekton.dev/git-0` annotation.

### Argo CD does not sync the promoted environment

Check:

```bash
oc get application -n openshift-gitops
```

and verify that the promotion commit reached the configured branch.

### The UI does not show release metadata

Check the generated ConfigMap in the target namespace:

```bash
oc get configmap demo-release -n mqtt-demo-test -o yaml
```

and confirm the API pod has the values as environment variables.
