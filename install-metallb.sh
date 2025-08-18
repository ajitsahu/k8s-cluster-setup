#!/usr/bin/env bash

set -e

# MetalLB version
METALLB_VERSION=v0.15.2

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please ensure kubectl is installed and configured."
    exit 1
fi

# Check if the cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Unable to connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
fi

echo "[Step 1] Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml || {
    echo "❌ Failed to install MetalLB"
    exit 1
}

echo "[Step 2] Waiting for MetalLB pods to be ready..."
if ! kubectl wait --namespace metallb-system \
  --for=condition=available deployment --all \
  --timeout=120s; then
    echo "❌ Timeout waiting for MetalLB pods"
    exit 1
fi

echo "[Step 3] Applying IPAddressPool and L2Advertisement..."
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-address-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.64.100-192.168.64.120   # Free range in same node subnet
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
EOF

echo "[Step 4] Verifying resources..."
kubectl get ipaddresspools.metallb.io -n metallb-system
kubectl get l2advertisements.metallb.io -n metallb-system

echo "✅ MetalLB installation and configuration completed!"
