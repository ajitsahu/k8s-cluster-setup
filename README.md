# Kubernetes Cluster setup script with Multipass and Kubeadm

This script automates the creation of a Kubernetes cluster using [Multipass](https://multipass.run/) and [Kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/). It sets up a control plane node and worker nodes, installs Calico as the CNI (Container Network Interface), and ensures proper cleanup in case of errors or interruptions.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Usage](#usage)
4. [Troubleshooting](#troubleshooting)
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

---

## Troubleshooting

### Common Issues and Solutions

1. **Script Gets Stuck Waiting for API Server**:
   - Ensure the `kube-apiserver` pod is running:
     ```bash
     multipass exec control -- sudo -u ubuntu kubectl --kubeconfig=/home/ubuntu/.kube/config get pods -n kube-system
     ```
   - Check the logs for the `kube-apiserver` pod:
     ```bash
     multipass exec control -- sudo -u ubuntu kubectl --kubeconfig=/home/ubuntu/.kube/config logs -n kube-system <kube-apiserver-pod-name>
     ```

2. **`kubectl` Commands Fail**:
   - Verify that the `.kube/config` file exists and is owned by the `ubuntu` user:
     ```bash
     multipass exec control -- ls -l /home/ubuntu/.kube/config
     ```
   - Test `kubectl` manually:
     ```bash
     multipass exec control -- sudo -u ubuntu kubectl --kubeconfig=/home/ubuntu/.kube/config get nodes
     ```

3. **Multipass Resource Limits**:
   - If you encounter resource-related errors, increase the CPU, memory, or disk allocation in the script:
     ```bash
     multipass launch -n <node-name> <image> -c <cpus> -m <memory> -d <disk-size>
     ```

4. **Firewall or Network Issues**:
   - Ensure that no firewall rules block communication between the control plane and worker nodes.

---

## Acknowledgments

- [Multipass](https://multipass.run/): For providing a lightweight and easy-to-use VM manager.
- [Kubernetes](https://kubernetes.io/): For the powerful container orchestration platform.
- [Calico](https://www.tigera.io/project-calico/): For the robust CNI solution.