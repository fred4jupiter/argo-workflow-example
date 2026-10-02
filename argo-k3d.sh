#!/usr/bin/env bash
# Create a local k3d cluster and deploy Argo Workflows into it.
#
# Usage:
#   ./argo-k3d.sh            # create cluster, install Argo, run a hello-world test
#   ./argo-k3d.sh delete     # delete the cluster
#
# Overridable via environment variables:
#   CLUSTER_NAME (default: argo)
#   ARGO_VERSION (default: v4.1.0)
#   ARGO_PORT    (default: 2746)  host port for the Argo UI
#   MINIO_ACCESS_KEY / MINIO_SECRET_KEY (default: admin / password)
#   SKIP_TEST=1  skip the smoke test

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-argo}"
ARGO_VERSION="${ARGO_VERSION:-v4.1.0}"
ARGO_PORT="${ARGO_PORT:-2746}"
NODE_PORT=32746
NAMESPACE=argo
CONTEXT="k3d-${CLUSTER_NAME}"
# Community MinIO build from Docker Hub (official minio/minio images are no longer published)
MINIO_IMAGE="docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-admin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-password}"
ARTIFACT_BUCKET=my-bucket

log() { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

kc() { kubectl --context "$CONTEXT" "$@"; }

check_deps() {
  for cmd in docker k3d kubectl; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed or not in PATH"
  done
  docker info >/dev/null 2>&1 || die "Docker daemon is not running"
}

create_cluster() {
  if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
    log "Cluster '$CLUSTER_NAME' already exists, reusing it"
    k3d cluster start "$CLUSTER_NAME" >/dev/null 2>&1 || true
  else
    log "Creating k3d cluster '$CLUSTER_NAME'"
    k3d cluster create "$CLUSTER_NAME" \
      --servers 1 \
      --port "${ARGO_PORT}:${NODE_PORT}@server:0" \
      --k3s-arg "--disable=traefik@server:0" \
      --k3s-arg "--disable=metrics-server@server:0" \
      --wait
  fi
  kubectl config use-context "$CONTEXT" >/dev/null
}

install_argo() {
  log "Installing Argo Workflows ${ARGO_VERSION}"
  kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f -
  kc apply -n "$NAMESPACE" --server-side --force-conflicts \
    -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/install.yaml"

  log "Enabling server auth mode (no login token needed in the UI)"
  if ! kc -n "$NAMESPACE" get deploy argo-server \
       -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q auth-mode; then
    kc -n "$NAMESPACE" patch deploy argo-server --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--auth-mode=server"}]'
  fi

  log "Exposing argo-server on NodePort ${NODE_PORT}"
  kc -n "$NAMESPACE" patch svc argo-server \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"web\",\"port\":2746,\"targetPort\":2746,\"nodePort\":${NODE_PORT}}]}}"

  log "Granting the default service account permission to run workflows"
  kc -n "$NAMESPACE" create rolebinding default-admin \
    --clusterrole=admin --serviceaccount="${NAMESPACE}:default" \
    --dry-run=client -o yaml | kc apply -f -

  log "Waiting for Argo components to become ready"
  kc -n "$NAMESPACE" rollout status deploy/workflow-controller --timeout=300s
  kc -n "$NAMESPACE" rollout status deploy/argo-server --timeout=300s
}

install_artifact_repo() {
  log "Installing MinIO as the default artifact repository"
  kc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-minio-cred
  labels:
    app: minio
stringData:
  accesskey: ${MINIO_ACCESS_KEY}
  secretkey: ${MINIO_SECRET_KEY}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  labels:
    app: minio
spec:
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      automountServiceAccountToken: false
      containers:
        - name: main
          image: ${MINIO_IMAGE}
          command: [minio, server, --console-address, ":9001", /data]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: {secretKeyRef: {name: my-minio-cred, key: accesskey}}
            - name: MINIO_ROOT_PASSWORD
              valueFrom: {secretKeyRef: {name: my-minio-cred, key: secretkey}}
          lifecycle:
            postStart:
              exec:
                command: [mkdir, -p, /data/${ARTIFACT_BUCKET}]
          ports:
            - {name: api, containerPort: 9000}
            - {name: dashboard, containerPort: 9001}
          readinessProbe:
            httpGet: {path: /minio/health/ready, port: 9000}
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /minio/health/live, port: 9000}
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  labels:
    app: minio
spec:
  selector:
    app: minio
  ports:
    - {name: api, port: 9000, targetPort: 9000}
    - {name: dashboard, port: 9001, targetPort: 9001}
EOF

  log "Configuring the workflow controller to use MinIO for artifacts"
  local repo_config
  repo_config=$(cat <<EOF
archiveLogs: true
s3:
  bucket: ${ARTIFACT_BUCKET}
  endpoint: minio.${NAMESPACE}.svc:9000
  insecure: true
  accessKeySecret:
    name: my-minio-cred
    key: accesskey
  secretKeySecret:
    name: my-minio-cred
    key: secretkey
EOF
)
  kc -n "$NAMESPACE" create configmap workflow-controller-configmap \
    --from-literal=artifactRepository="$repo_config" \
    --dry-run=client -o json \
    | kc -n "$NAMESPACE" patch configmap workflow-controller-configmap \
        --type merge --patch-file /dev/stdin

  kc -n "$NAMESPACE" rollout status deploy/minio --timeout=300s
}

smoke_test() {
  log "Submitting smoke test workflow (passes an artifact between two steps)"
  local wf
  wf=$(kc -n "$NAMESPACE" create -o name -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: smoke-test-
spec:
  entrypoint: main
  templates:
    - name: main
      steps:
        - - name: produce
            template: produce
        - - name: consume
            template: consume
            arguments:
              artifacts:
                - name: message
                  from: "{{steps.produce.outputs.artifacts.message}}"
    - name: produce
      container:
        image: busybox:1.36
        command: [sh, -c]
        args: ["echo 'hello from Argo Workflows' > /tmp/message.txt"]
      outputs:
        artifacts:
          - name: message
            path: /tmp/message.txt
    - name: consume
      inputs:
        artifacts:
          - name: message
            path: /tmp/message.txt
      container:
        image: busybox:1.36
        command: [cat, /tmp/message.txt]
EOF
)
  if kc -n "$NAMESPACE" wait "$wf" \
       --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null; then
    log "Smoke test passed (${wf#*/})"
  else
    kc -n "$NAMESPACE" get "$wf" -o jsonpath='{.status.phase}{" - "}{.status.message}{"\n"}' || true
    die "Smoke test workflow did not succeed"
  fi
}

delete_cluster() {
  log "Deleting k3d cluster '$CLUSTER_NAME'"
  k3d cluster delete "$CLUSTER_NAME"
}

main() {
  check_deps
  case "${1:-up}" in
    up)
      create_cluster
      install_argo
      install_artifact_repo
      [[ "${SKIP_TEST:-0}" == "1" ]] || smoke_test
      echo
      log "Argo Workflows is ready"
      echo "   UI:          https://localhost:${ARGO_PORT}  (self-signed cert, accept the warning)"
      echo "   kube context: ${CONTEXT}"
      echo "   Submit:      argo submit -n ${NAMESPACE} --watch <workflow.yaml>"
      echo "   Tear down:   $0 delete"
      ;;
    delete) delete_cluster ;;
    *) die "Unknown command '$1' (use: up | delete)" ;;
  esac
}

main "$@"
