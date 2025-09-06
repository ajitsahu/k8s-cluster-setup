# Kubernetes Cluster setup script with Multipass and Kubeadm

This script automates the creation of a Kubernetes cluster using [Multipass](https://multipass.run/) and [Kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/). It sets up a control plane node and worker nodes, installs Calico as the CNI (Container Network Interface), and ensures proper cleanup in case of errors or interruptions.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Usage](#usage)
   - [What Happens During Execution?](#what-happens-during-execution)
4. [Addons Installation](#addons-installation)
   - [Installing MetalLB Load Balancer](#installing-metallb-load-balancer)
   - [Dynamic Local Storage Configuration](#installing-dynamically-provisioning-persistent-local-storage)
   - [Monitoring](#monitoring)
   - [Istio Setup](#istio-setup)
5. [Acknowledgments](#acknowledgments)

---

## Prerequisites

Before running the script, ensure the following:

1. **Operating System**:
   - Tested on **Mac m3 (ARM architecture)**.
   - Should also work on Linux and other Unix-like systems with Multipass installed.

2. **Software Dependencies**:
   - [Multipass](https://canonical.com/multipass): A lightweight VM manager for launching Ubuntu instances.
     - Install Multipass by following the [official installation guide](https://canonical.com/multipass/install).
   - Bash: The script is written in Bash and requires a Bash-compatible shell.

3. **Hardware Requirements**:
   - At least **4 CPUs**, **8 GB RAM**, and **20 GB disk space** are recommended to run the cluster comfortably.

4. **Network Configuration**:
   - Ensure that your system has internet access and can resolve external DNS queries.

---

## Installation

1. Clone or download the script to your local machine:
   ```bash
   git clone https://github.com/ajitsahu/k8s-cluster-setup.git
   cd k8s-cluster-setup
   ```

2. Make the script executable:
   ```bash
   chmod +x create-k8s-cluster.sh
   ```

3. (Optional) Review and modify the configuration parameters in the script if needed:
   - `POD_CIDR`: Pod network CIDR (default: `10.244.0.0/16`).
   - `KUBERNETES_VERSION`: Kubernetes version (default: `v1.32`).
   - `CALICO_VERSION`: Calico version (default: `v3.29.2`).

---

## Usage

Run the script to create the Kubernetes cluster:
```bash
./create-k8s-cluster.sh
```

### What Happens During Execution?
1. **Launch Multipass Instances**:
   - A control plane node (`control`) and two worker nodes (`node1`, `node2`) are created using Multipass.
   - Control node is allocated 2 CPUs, 2 GB RAM, and 10 GB disk space.
   - Worker node allocated 1 CPUs, 2 GB RAM, and 10 GB disk space.

2. **Install Kubernetes Components**:
   - Installs `kubelet`, `kubeadm`, `kubectl`, and `containerd` on all nodes.

3. **Initialize the Control Plane**:
   - Initializes the Kubernetes control plane on the `control` node using `kubeadm`.

4. **Install Calico Networking**:
   - Deploys the Tigera Operator and applies Calico's custom resources for networking.

5. **Join Worker Nodes**:
   - Joins the worker nodes to the cluster using the `kubeadm join` command.

6. **Cleanup**:
   - If the script fails or is interrupted, it automatically cleans up all Multipass instances to prevent resource leaks.

Copy kubeconfig to your local machine for `kubectl` access:
```bash
multipass transfer control:/home/ubuntu/.kube/config ./kubeconfig
export KUBECONFIG=$PWD/.kubeconfig
``` 
## Addons Installation
After setting up the cluster, you can install additional addons like MetalLB for LoadBalancer services and a dynamic local storage provisioner.

### Installing MetalLB Load Balancer

After setting up the cluster, you can install MetalLB to enable LoadBalancer services:

1. Make the MetalLB installation script executable:
   ```bash
   chmod +x install-metallb.sh
   ```

2. Run the installation script:
   ```bash
   ./install-metallb.sh 192.168.64.200-192.168.64.220
   ```

The script will:
- Install MetalLB components in the `metallb-system` namespace
- Configure an IP address pool (e.g. 192.168.64.200-192.168.64.220)
- Set up L2 advertisement for LoadBalancer services

To verify the installation:
```bash
kubectl get pods -n metallb-system
```

You can now create LoadBalancer services that will automatically receive IP addresses from the configured pool.

### Installing Dynamically Provisioning Persistent Local Storage

To set up dynamically provisioning persistent local storage with Kubernetes, you can use the Rancher Local Path Provisioner:

1. Install the local-path-provisioner:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.32/deploy/local-path-storage.yaml
   ```

2. Make it the default StorageClass:
   ```bash
   kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
   ```

3. Verify the StorageClass:
   ```bash
   kubectl get storageclass
   ```

For more information, visit the [Rancher Local Path Provisioner GitHub repository](https://github.com/rancher/local-path-provisioner).

### Monitoring

For comprehensive monitoring of your Kubernetes cluster, refer to the [monitoring setup guide](monitoring.md) which includes instructions for installing Prometheus, Grafana, and metrics-server.

### Istio Setup
To set up Istio service mesh in your Kubernetes cluster, follow the instructions in the [Istio setup guide](istio-setup.md). This guide covers installation, configuration, and basic usage of Istio features.

---
## Acknowledgments

- [Multipass](https://multipass.run/): For providing a lightweight and easy-to-use VM manager.
- [Kubernetes](https://kubernetes.io/): For the powerful container orchestration platform.
- [Calico](https://www.tigera.io/project-calico/): For the robust CNI solution.
- [MetalLB](https://metallb.io/): For the load-balancer implementation.
- [metrics-server](https://github.com/kubernetes-sigs/metrics-server): For the monitoring stack.
- [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics): For monitoring Kubernetes resources.
