#!/usr/bin/env bash
set -euo pipefail

CLUSTER=ha-cluster
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HA_CONFIG="$REPO_ROOT/03-installation-and-setup/kind-ha-config.yaml"
JWST_MANIFEST="$REPO_ROOT/03-installation-and-setup/jwst-app.yaml"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"

echo "==> Deleting existing cluster (if any)"
kind delete cluster --name "$CLUSTER" 2>/dev/null || true

echo "==> Creating cluster"
kind create cluster --name "$CLUSTER" --config "$HA_CONFIG"

echo "==> Deploying NGINX ingress controller"
kubectl apply -f "$INGRESS_MANIFEST" --context "kind-$CLUSTER"

echo "==> Patching ingress controller onto ingress-ready node"
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --context "kind-$CLUSTER" \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/nodeSelector/ingress-ready","value":"true"}]'

echo "==> Waiting for ingress controller"
kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx \
  --context "kind-$CLUSTER" \
  --timeout=120s

echo "==> Deploying JWST app (retrying until webhook is ready)"
until kubectl apply -f "$JWST_MANIFEST" --context "kind-$CLUSTER" 2>&1 | grep -v "connection refused"; do
  sleep 5
done

echo "==> Waiting for JWST app"
kubectl rollout status deployment/jwst-app \
  --context "kind-$CLUSTER" \
  --timeout=60s

echo ""
echo "Done. Cluster is up at http://localhost"
