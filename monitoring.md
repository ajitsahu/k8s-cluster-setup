# Installing Prometheus Monitoring Stack

To set up comprehensive monitoring for your Kubernetes cluster, you can install the Prometheus monitoring stack including kube-state-metrics and metrics-server:

1. **Add required Helm repositories**:
   ```bash
   helm repo add prometheus https://prometheus-community.github.io/helm-charts
   helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
   helm repo add grafana https://grafana.github.io/helm-charts
   ```

2. **Update Helm repositories**:
   ```bash
   helm repo update
   ```

3. **Create monitoring namespace**:
   ```bash
   kubectl create namespace monitoring
   ```

4. **Install kube-state-metrics**:
   ```bash
   helm install kube-state-metrics prometheus/kube-state-metrics --namespace monitoring --version 6.3.0
   ```

5. **Install metrics-server**:
   ```bash
   helm install metrics-server metrics-server/metrics-server -n monitoring --version 3.12.2
   ```

# Managing Metrics Server Versions

To check available versions of metrics-server:

```bash
helm search repo metrics-server/metrics-server --versions
```

To preview changes before upgrading metrics-server:

```bash
helm diff upgrade metrics-server metrics-server/metrics-server -n monitoring --version 3.13.0
```

# Verifying Monitoring Installation

After installation, verify that all monitoring components are running:

```bash
# Check kube-state-metrics
kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics

# Check metrics-server
kubectl get pods -n monitoring -l app.kubernetes.io/name=metrics-server

# Check cluster metrics
kubectl top nodes
kubectl top pods -A
```

If metrics-server pods are not ready due to certificate issues, apply this patch:

```bash
kubectl patch deployment metrics-server -n monitoring --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

# Install Prometheus with Custom Values

To install Prometheus with custom values, create a `prometheus-values.yaml` file with the following content:

```yaml
# Disable redundant components
kubeStateMetrics:
  enabled: false
grafana:
  enabled: false

# Configure Prometheus storage
prometheus:
  prometheusSpec:
    retention: 24h                    # Reduce retention to save space
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          resources:
            requests:
              storage: 1Gi           # Fits your 1–2 GB limit
          accessModes:
            - ReadWriteOnce
```

Then install Prometheus using Helm:

```bash
helm install prometheus prometheus/kube-prometheus-stack --namespace monitoring -f prometheus-values.yaml
```

# Installing Grafana for Visualization

To install Grafana with custom values, create a `grafana-values.yaml` file with the following content:

```yaml
# Enable persistence using PVC
persistence:
  enabled: true
  type: pvc
  size: 1Gi
  storageClassName: local-path

# Expose via NodePort
service:
  type: NodePort
  nodePort: 30080

# Admin password
adminPassword: monitoring123

# Data source configuration
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        # Use FQDN if Prometheus in a different ns, e.g. prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
        url: http://prometheus-kube-prometheus-prometheus:9090
        access: proxy
        isDefault: true

# Pre-installed dashboards
dashboards:
  default:
    node-exporter:
      gnetId: 1860
      revision: 110
      datasource: Prometheus
    coredns:
      gnetId: 15762
      revision: 21
      datasource: Prometheus
```

Then install Grafana using Helm:

```bash
helm install grafana grafana/grafana -n monitoring -f grafana-values.yaml
```

# Accessing Prometheus and Grafana

To access Prometheus:

```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```

To access Grafana via NodePort:

```
http://<multipass-ip-address>:30080
```

The default Grafana credentials are:
- Username: admin
- Password: monitoring123 