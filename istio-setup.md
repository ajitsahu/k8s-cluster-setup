# Istio Ambient Mesh with Shared Gateway API Setup Guide

This guide provides a structured walkthrough for deploying Istio in ambient mode on a Kubernetes cluster. It covers the installation of prerequisites, Istio itself, a shared ingress gateway using the Gateway API, and a sample application with a waypoint proxy for L7 processing.

## Step 1: Prerequisites

Before installing Istio, you need a Kubernetes cluster and the following components.

### 1.1. Install MetalLB [reference](install-metallb.sh) for Gateway API LoadBalancer Services (Optional)

### 1.2. Install Kubernetes Gateway API CRDs

Istio uses the Kubernetes Gateway API for traffic management. Install the necessary Custom Resource Definitions (CRDs).

```bash
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
```

## Step 2: Install Istio with Ambient Profile

Use Helm to install the core Istio components required for the ambient mesh profile.

```bash
# Add the Istio Helm repository
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# 1. Install the Istio base chart (contains CRDs)
helm install istio-base istio/base -n istio-system --create-namespace --wait

# 2. Install istiod with the ambient profile enabled
helm install istiod istio/istiod --namespace istio-system --set profile=ambient --wait

# 3. Install the Istio CNI component
helm install istio-cni istio/cni -n istio-system --set profile=ambient --wait

# 4. Install the ztunnel component for the ambient data plane
helm install ztunnel istio/ztunnel -n istio-system --wait

# Verify the Istio installation
helm ls -n istio-system
kubectl get pods -n istio-system
```

## Step 3: Set Up the Shared Ingress Gateway

We will create a centralized ingress gateway in a dedicated `networking` namespace. This gateway will handle all incoming traffic for multiple tenant applications.

### 3.1. Create a Namespace for the Gateway

```bash
kubectl create ns networking
```

### 3.2. Generate TLS Certificates

Create a self-signed wildcard certificate for `*.example.com` to secure the gateway.

```bash
# Create a directory for certs
mkdir -p wildcard_certs

# Generate the certificate authority (CA) and the server certificate
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -keyout wildcard_certs/ca.key -out wildcard_certs/ca.crt \
  -subj "/O=Example Inc./CN=Example Root CA"

openssl req -new -nodes -newkey rsa:2048 \
  -keyout wildcard_certs/wildcard.example.com.key \
  -out wildcard_certs/wildcard.example.com.csr \
  -subj "/CN=*.example.com/O=Example Inc."

openssl x509 -req -sha256 -days 365 \
  -in wildcard_certs/wildcard.example.com.csr \
  -CA wildcard_certs/ca.crt -CAkey wildcard_certs/ca.key -CAcreateserial \
  -out wildcard_certs/wildcard.example.com.crt \
  -extfile <(printf "subjectAltName=DNS:*.example.com,DNS:example.com")

# Create the Kubernetes secret in the 'networking' namespace
kubectl create secret tls wildcard-certs \
  --key=wildcard_certs/wildcard.example.com.key \
  --cert=wildcard_certs/wildcard.example.com.crt \
  --namespace=networking
```

### 3.3. Deploy the Gateway Resource

This `Gateway` resource defines the entry point for traffic, listening on ports 80 and 443. It is configured to allow `HTTPRoute` resources from all namespaces to attach to it.

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: networking
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.example.com"
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "*.example.com"
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        group: ""
        name: wildcard-certs
    allowedRoutes:
      namespaces:
        from: All
EOF
```

## Step 4: Deploy a Sample Application

Now, deploy a sample `httpbin` application in its own namespace and expose it via the shared gateway.

### 4.1. Create and Label the Application Namespace

Create a namespace and label it to be part of the ambient mesh.

```bash
kubectl create ns sample
kubectl label namespace sample istio.io/dataplane-mode=ambient
kubectl get ns -L istio.io/dataplane-mode
```

### 4.2. Deploy the httpbin Application

```bash
kubectl apply -n sample -f - <<EOF
# Copyright Istio Authors
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 8080
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - image: docker.io/mccutchen/go-httpbin:v2.15.0
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 8080
EOF
```

### 4.3. Expose the Application with an HTTPRoute

Create an `HTTPRoute` to route traffic for `httpbin.example.com` from the `shared-gateway` to the `httpbin` service.

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: sample
spec:
  parentRefs:
  - name: shared-gateway
    namespace: networking # Must point to the shared Gateway
  hostnames: ["httpbin.example.com"]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    - path:
        type: PathPrefix
        value: /status
    backendRefs:
    - name: httpbin
      port: 8000
EOF
```

## Step 5: Enable L7 Processing with a Waypoint Proxy

To apply L7 policies (like `AuthorizationPolicy`), you must deploy a waypoint proxy for the `sample` namespace. The waypoint proxy will intercept all L7 traffic for services within this namespace.

```bash
# This command creates a Gateway resource for the waypoint and enrolls the namespace to use it.
istioctl waypoint apply -n sample --enroll-namespace

# Verify the waypoint proxy deployment
kubectl get gateway -n sample
```

## Step 6: Enforce Mesh-Wide Security (mTLS)

For a secure multi-tenant environment, it is highly recommended to enforce strict mTLS for all service-to-service communication within the mesh. This ensures all internal traffic is authenticated and encrypted.

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: sample
spec:
  mtls:
    mode: STRICT
EOF
```

The resulting traffic flow is: **Client --(HTTPS)--> Gateway --(mTLS)--> Waypoint Proxy --(mTLS)--> Service**

## Step 7: Verification

Verify that the entire setup is working correctly by sending requests to your application.

### 7.1. Get Gateway IP and Port

```bash
export INGRESS_HOST=$(kubectl get gtw shared-gateway -n networking -o jsonpath='{.status.addresses[0].value}')
export INGRESS_PORT_HTTP=$(kubectl get gtw shared-gateway -n networking -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export INGRESS_PORT_HTTPS=$(kubectl get gtw shared-gateway -n networking -o jsonpath='{.spec.listeners[?(@.name=="https")].port}')

echo "Gateway Host: $INGRESS_HOST"
echo "Gateway HTTP Port: $INGRESS_PORT_HTTP"
echo "Gateway HTTPS Port: $INGRESS_PORT_HTTPS"
```

### 7.2. Test HTTP Access (Without TLS)

```bash
curl -s -I -HHost:httpbin.example.com "http://$INGRESS_HOST:$INGRESS_PORT_HTTP/status/200"
```

You should receive an `HTTP/1.1 200 OK` response.

### 7.3. Test HTTPS Access (With TLS)

Use the `--resolve` flag to manually point the domain to your gateway's IP, and `--cacert` to trust your self-signed CA.

```bash
curl -v --cacert wildcard_certs/ca.crt \
  -H "Host: httpbin.example.com" \
  --resolve "httpbin.example.com:$INGRESS_PORT_HTTPS:$INGRESS_HOST" \
  "https://httpbin.example.com:$INGRESS_PORT_HTTPS/status/200"
```

You should see a successful TLS handshake and receive a `200 OK` response.

### 7.4. Inspect Istio Configurations

```bash
# Check the status of the Gateway and HTTPRoute
kubectl get gateway shared-gateway -n networking
kubectl get httproute httpbin-route -n sample

# Check PeerAuthentication policies across the mesh
kubectl get peerauthentication --all-namespaces

# Inspect the routes configured on the ingress gateway pod
istioctl proxy-config routes \
  $(kubectl get pod -n istio-system -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}') \
  -n istio-system --name http.80 -o json

# Check the secrets (certificates) loaded by a service pod
# (Note: In ambient mode, secrets are managed by ztunnel/waypoint, not individual pods)
istioctl proxy-config secret \
  $(kubectl get pod -n sample -l app=httpbin -o jsonpath='{.items[0].metadata.name}') \
  -n sample -o json
```

## Appendix: Understanding the Request Flow

1.  **Client Request**: A user sends a request to `https://httpbin.example.com/status/200`.
2.  **DNS Resolution**: DNS resolves `httpbin.example.com` to the external IP address of your Load Balancer (e.g., `192.168.64.100` from MetalLB).
3.  **Load Balancer**: The request hits the Load Balancer on port 443, which forwards it to a `NodePort` on one of the Kubernetes worker nodes.
4.  **Kubernetes Service**: The `NodePort` directs the traffic to the `istio-ingressgateway` Kubernetes `Service` in the `istio-system` namespace.
5.  **Gateway Pod**: The request arrives at the ingress gateway pod.
6.  **TLS Termination**: The gateway terminates the TLS session using the `wildcard-certs` secret.
7.  **Host Matching**: The gateway inspects the `Host` header (`httpbin.example.com`).
8.  **Route Matching**: It finds the `httpbin-route` `HTTPRoute` that matches the host.
9.  **Waypoint Forwarding**: The route rule forwards the traffic to the `httpbin` service in the `sample` namespace. Because the namespace is managed by a waypoint, the gateway forwards the request to the `sample-waypoint` proxy first.
10. **Authorization & Forwarding**: The waypoint proxy applies any L7 `AuthorizationPolicy` and then forwards the request to the actual `httpbin` pod.
11. **Response**: The `httpbin` pod processes the request and returns a `200 OK` response, which travels back along the same path.