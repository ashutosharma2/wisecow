#!/usr/bin/env bash
# Create (or reuse) a kind cluster and install the cluster add-ons wisecow
# depends on: Traefik (ingress controller) and cert-manager (TLS certificates).
#
# Usage: hack/setup-cluster.sh
# Env:   CLUSTER_NAME (default: wisecow)
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-wisecow}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-42.4.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.3}"
HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n==> %s\n' "$*"; }

for bin in kind kubectl helm; do
  command -v "$bin" >/dev/null || { echo "error: $bin is not installed" >&2; exit 1; }
done

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists, reusing it"
else
  log "Creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --config "$HACK_DIR/kind-config.yaml" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

log "Installing Traefik ingress controller (chart $TRAEFIK_CHART_VERSION)"
helm upgrade --install traefik traefik \
  --repo https://traefik.github.io/charts \
  --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik --create-namespace \
  --values "$HACK_DIR/traefik-values.yaml" \
  --wait --timeout 5m

log "Installing cert-manager $CERT_MANAGER_VERSION"
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 5m

log "Cluster is ready"
kubectl get pods -n traefik
kubectl get pods -n cert-manager
