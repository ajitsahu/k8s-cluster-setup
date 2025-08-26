#!/usr/bin/env bash

set -e

# MetalLB version
METALLB_VERSION=v0.15.2

# Function to show usage
show_usage() {
    echo "Usage: $0 <IP-RANGE>"
    echo "Example: $0 192.168.64.100-192.168.64.120"
    echo ""
    echo "⚠️  IMPORTANT: Please check VMs IP range with the command 'multipass list' and put free IP range"
    echo "    Command to check: multipass list"
    exit 1
}

# Function to validate IP range format
validate_ip_range() {
    local range=$1
    # Check if the range matches the format: IP-IP
    if ! [[ $range =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "❌ Invalid IP range format. Expected format: START_IP-END_IP (e.g., 192.168.64.100-192.168.64.120)"
        exit 1
    fi
    
    # Extract start and end IPs
    local start_ip=${range%-*}
    local end_ip=${range#*-}
    
    # Validate each IP
    for ip in "$start_ip" "$end_ip"; do
        if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "❌ Invalid IP address: $ip"
            exit 1
        fi
        # Validate each octet
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ $octet -lt 0 || $octet -gt 255 ]]; then
                echo "❌ Invalid IP address: $ip (octets must be between 0 and 255)"
                exit 1
            fi
        done
    done
}

# Check if IP range is provided
if [ $# -ne 1 ]; then
    show_usage
fi

IP_RANGE=$1
validate_ip_range "$IP_RANGE"

echo "ℹ️  Using IP range: $IP_RANGE"

# Display current VM IPs for reference
echo "Current Multipass VMs:"
multipass list || echo "❌ Failed to list Multipass VMs. Please check them manually."
echo ""

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
  - ${IP_RANGE}   # User provided or default IP range
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
