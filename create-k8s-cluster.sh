########################################################################################
# Title: Create a Kubernetes Cluster with Multipass
# Description: This script creates a Kubernetes cluster with one control plane node and
#             two worker nodes using Multipass.
########################################################################################
#!/usr/bin/env bash

set -euo pipefail  # Enable strict mode

# ============================
# Configuration and Parameters
# ============================
POD_CIDR=${POD_CIDR:-"10.244.0.0/16"}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-"v1.32"}
CALICO_VERSION=${CALICO_VERSION:-"v3.29.2"}

CONTROL_NODE="control"
WORKER_NODES=("node1" "node2")
ALL_NODES=("$CONTROL_NODE" "${WORKER_NODES[@]}")
LOG_FILE="setup.log"

CLEANUP_REQUIRED=1  # Default: Cleanup is required (1 = true, 0 = false)

# ============================
# Helper Functions
# ============================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Modified cleanup function to delete only specific instances
cleanup() {
    if [[ $CLEANUP_REQUIRED -eq 1 ]]; then
        log "Cleaning up specified Multipass instances..."
        for node in "${ALL_NODES[@]}"; do
            if multipass list | grep -q "^$node "; then
                log "Deleting Multipass instance: $node"
                multipass delete "$node" || true
            else
                log "Multipass instance '$node' not found, skipping deletion."
            fi
        done
        log "Purging deleted instances to reclaim disk space..."
        multipass purge || true
        log "Cleanup of specified instances completed."
    else
        log "Skipping cleanup as the script completed successfully."
    fi
}

trap cleanup EXIT  # Automatically clean up on script exit unless CLEANUP_REQUIRED=0

validate_ip() {
    local ip=$1
    if [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "Invalid IP address detected: $ip"
        exit 1
    fi
}

wait_for_pods() {
    local namespace=$1
    local timeout=300  # 5 minutes timeout
    local end_time=$((SECONDS + timeout))
    log "Waiting for pods in namespace '$namespace' to be ready..."

    while true; do
        # Get the status of all pods in the namespace
        pod_ready_status=$(multipass exec $CONTROL_NODE -- sudo -u ubuntu kubectl get pods -n $namespace -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}')

        # Check if all pods are ready
        if [[ "$pod_ready_status" == *"True"* && "$pod_ready_status" != *"False"* ]]; then
            log "All pods in namespace '$namespace' are ready."
            break
        fi

        # Check for timeout
        if [[ $SECONDS -gt $end_time ]]; then
            log "Timeout waiting for pods in namespace '$namespace' to be ready."
            multipass exec $CONTROL_NODE -- sudo -u ubuntu kubectl get pods -n $namespace
            exit 1
        fi

        # Log progress and wait before retrying
        log "Pods in namespace '$namespace' are not ready yet. Retrying in 10 seconds..."
        sleep 10
    done
}

# ============================
# Main Functions
# ============================
launch_instances() {
    log "Launching Multipass instances..."
    # Launch only the control node initially
    multipass launch -n $CONTROL_NODE 24.04 -c 2 -m 4G -d 10G || { log "Failed to launch control node"; exit 1; }
    log "Control instance launched successfully."
}

# Renamed function to install on a single specified node
install_kubernetes_components() {
    local node=$1
    log "Installing Kubernetes components on node: $node"
    multipass exec $node -- sudo bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && \\
        apt-get install -y apt-transport-https ca-certificates curl gpg && \\
        curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && \\
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list && \\
        cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF
        sysctl --system && \\
        sysctl net.ipv4.ip_forward && \\
        apt-get update && \\
        apt-get install -y kubelet kubeadm kubectl && \\
        apt-mark hold kubelet kubeadm kubectl && \\
        apt-get install -y containerd && \\
        mkdir -p /etc/containerd && \\
        containerd config default | \\
        sed -e 's/SystemdCgroup = false/SystemdCgroup = true/' \\
            -e 's|sandbox_image = \"registry.k8s.io/pause:[0-9.]*\"|sandbox_image = \"registry.k8s.io/pause:3.10\"|' | \\
        tee /etc/containerd/config.toml && \\
        cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF
        systemctl restart containerd
    "
    log "Kubernetes components installed successfully on $node."
}

create_worker_nodes() {
    log "Creating worker nodes by cloning control node..."
    
    # Stop the control node before cloning
    log "Stopping control node for cloning...Sleep 20s..."
    sleep 20
    multipass stop "$CONTROL_NODE" || { log "Failed to stop control node"; exit 1; }
    
    # Create worker nodes by cloning the control node
    for worker in "${WORKER_NODES[@]}"; do
        log "Cloning control node to create worker node: $worker"
        multipass clone "$CONTROL_NODE" -n "$worker" || { log "Failed to clone control node to $worker"; exit 1; }
    done
    
    # Start all nodes
    log "Starting all nodes..."
    multipass start "${ALL_NODES[@]}" || { log "Failed to start nodes"; exit 1; }
    
    # Wait for nodes to be ready
    sleep 15
    log "All worker nodes created by cloning successfully."
}

initialize_control_plane() {
    log "Initializing Kubernetes control plane on $CONTROL_NODE..."
    CONTROL_IP=$(multipass info $CONTROL_NODE | grep IPv4 | awk '{print $2}')
    validate_ip "$CONTROL_IP"
    multipass exec $CONTROL_NODE -- sudo bash -c "
        set -e
        kubeadm init --apiserver-advertise-address $CONTROL_IP --pod-network-cidr $POD_CIDR --upload-certs
    "
    log "Control plane initialized successfully."

    # Verify and copy admin.conf for the ubuntu user
    log "Verifying existence of /etc/kubernetes/admin.conf..."
    multipass exec $CONTROL_NODE -- sudo bash -c "
        if [[ ! -f /etc/kubernetes/admin.conf ]]; then
            echo 'Error: /etc/kubernetes/admin.conf not found!'
            exit 1
        fi
    "

    log "Copying admin.conf to /home/ubuntu/.kube/config..."
    multipass exec $CONTROL_NODE -- sudo bash -c "
        set -e
        mkdir -p /home/ubuntu/.kube && \
        cp -v /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && \
        chown ubuntu:ubuntu /home/ubuntu/.kube/config
    "

    # Wait for the API server to be ready
    log "Waiting for Kubernetes API server to be ready..."
    until multipass exec $CONTROL_NODE -- sudo -u ubuntu kubectl get nodes; do
        log "Kubernetes API server not ready yet. Retrying in 5 seconds..."
        sleep 5
    done
    log "Kubernetes API server is ready."
}

install_calico() {
    log "Installing Calico networking..."

    # Step 1: Apply the Tigera Operator manifest
    multipass exec $CONTROL_NODE -- sudo -u ubuntu bash -c "
        set -e
        kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml --validate=false
    "
    log "Tigera Operator manifest applied successfully."

    # Step 2: Wait for Tigera Operator pods to be ready
    log "Waiting for Tigera Operator pods to be ready..."
    until multipass exec $CONTROL_NODE -- sudo -u ubuntu kubectl get pods -n tigera-operator -o jsonpath='{.items[*].status.phase}' | grep -q "Running"; do
        log "Tigera Operator pods not ready yet. Retrying in 5 seconds..."
        sleep 5
    done
    log "Tigera Operator pods are ready."

    # Step 3: Download and modify the custom-resources.yaml file
    log "Downloading and modifying custom-resources.yaml..."
    multipass exec $CONTROL_NODE -- sudo -u ubuntu bash -c "
        set -e
        curl -O https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/custom-resources.yaml && \
        sed -i 's|192.168.0.0/16|$POD_CIDR|g' custom-resources.yaml
    "
    log "Custom-resources.yaml updated with POD_CIDR=$POD_CIDR."

    # Step 4: Apply the modified custom-resources.yaml file
    multipass exec $CONTROL_NODE -- sudo -u ubuntu bash -c "
        set -e
        kubectl create -f custom-resources.yaml --validate=false
    "
    log "Custom resources applied successfully."

    # Step 5: Wait for Calico pods to be ready
    wait_for_pods "calico-system"
    log "Calico networking installed successfully."
}

install_calicoctl() {
    log "Installing calicoctl on the control node..."

    # Download the calicoctl binary for ARM64
    multipass exec $CONTROL_NODE -- sudo bash -c "
        set -e
        curl -L https://github.com/projectcalico/calico/releases/download/$CALICO_VERSION/calicoctl-linux-arm64 -o /usr/local/bin/calicoctl && \
        chmod +x /usr/local/bin/calicoctl
    "
    log "calicoctl installed successfully."
}

join_worker_nodes() {
    log "Joining worker nodes to the cluster..."
    JOIN_COMMAND=$(multipass exec $CONTROL_NODE -- kubeadm token create --print-join-command)
    
    # Wait for control plane to be ready before joining nodes
    log "Waiting for control plane to be ready..."
    sleep 10

    for node in "${WORKER_NODES[@]}"; do
        log "Joining and labeling worker node: $node"
        multipass exec $node -- sudo bash -c "$JOIN_COMMAND" || { log "Failed to join node $node"; exit 1; }
        
        # Wait a few seconds for the node to be registered
        sleep 5
        
        # Label the worker node after successful join
        multipass exec $CONTROL_NODE -- sudo -u ubuntu kubectl label node $node node-role.kubernetes.io/worker=worker --overwrite=true || { log "Failed to label node $node"; exit 1; }
        log "Successfully joined and labeled node: $node"
    done
    log "All worker nodes joined and labeled successfully."
}

# ============================
# Main Execution
# ============================
main() {
    log "Starting Kubernetes cluster setup..."
    
    # Step 1: Launch and configure control plane node
    launch_instances
    install_kubernetes_components "$CONTROL_NODE"
    
    # Step 2: Create and configure worker nodes
    create_worker_nodes
    
    # Step 3: Initialize control plane
    initialize_control_plane
    
    # Step 4: Install CNI (Calico)
    install_calico
    install_calicoctl
    
    # Step 5: Join worker nodes
    join_worker_nodes
    
    # Print cluster status
    multipass exec $CONTROL_NODE -- sudo -u ubuntu kubectl get nodes -o wide
    
    log "Kubernetes cluster setup completed successfully!"
    CLEANUP_REQUIRED=0  # No cleanup needed if everything succeeds
}

main