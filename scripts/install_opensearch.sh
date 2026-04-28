#!/bin/bash
# Install Helm, OpenSearch, and Dashboards
# Run once as neranjana after k3s is ready

set -e

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add opensearch https://opensearch-project.github.io/helm-charts/
helm repo update

# Create namespace
kubectl create namespace logging

# Install OpenSearch from repo config (no temp files)
helm install opensearch opensearch/opensearch \
  -f configs/opensearch-values.yaml \
  -n logging

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/component=opensearch \
  -n logging --timeout=300s

# Install Dashboards from repo config
helm install dashboards opensearch/opensearch-dashboards \
  -f configs/dashboards-values.yaml \
  -n logging

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=opensearch-dashboards \
  -n logging --timeout=300s

echo "OpenSearch and Dashboards ready"
echo "Port-forward commands:"
echo "  kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging"
echo "  kubectl port-forward svc/dashboards-opensearch-dashboards 5601:5601 -n logging"
