#!/usr/bin/env bash
# Deploy wisecow to the current kubectl context, pinned to a specific image.
#
# Usage: hack/deploy.sh <image>
#   <image> may be name:tag or name@sha256:digest, e.g.
#     hack/deploy.sh wisecow:local
#     hack/deploy.sh ghcr.io/owner/wisecow@sha256:abc...
#
# The manifests in k8s/ are left untouched: a throwaway kustomize overlay
# swaps in the requested image, so the same command works locally and in CI.
set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
NAMESPACE="wisecow"
DEFAULT_IMAGE_NAME="ghcr.io/ashutosharma2/wisecow"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Split the reference into name + tag/digest for kustomize.
if [[ "$IMAGE" == *@* ]]; then
  name="${IMAGE%@*}"; field="digest: ${IMAGE#*@}"
elif [[ "${IMAGE##*/}" == *:* ]]; then
  name="${IMAGE%:*}"; field="newTag: \"${IMAGE##*:}\""
else
  name="$IMAGE"; field="newTag: latest"
fi

overlay="$(mktemp -d)"
trap 'rm -rf "$overlay"' EXIT
cp -R "$ROOT_DIR/k8s" "$overlay/base"
cat > "$overlay/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base
images:
  - name: $DEFAULT_IMAGE_NAME
    newName: $name
    $field
YAML

echo "==> Deploying $IMAGE"
kubectl apply -k "$overlay"

echo "==> Waiting for rollout"
if ! kubectl -n "$NAMESPACE" rollout status deployment/wisecow --timeout=180s; then
  echo "Rollout failed. Recent events:" >&2
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -20 >&2
  exit 1
fi

echo "==> Waiting for TLS certificate"
kubectl -n "$NAMESPACE" wait certificate/wisecow-tls --for=condition=Ready --timeout=120s

kubectl -n "$NAMESPACE" get deploy,pods,svc,ingress,certificate -o wide
