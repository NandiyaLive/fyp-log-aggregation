#!/bin/bash
# Monitor resources during experiment runs

echo "=== System Resources ==="
free -h
echo ""

echo "=== k3s Pods ==="
kubectl top pods -n logging 2>/dev/null || echo "metrics-server not available"
echo ""

echo "=== Node Resources ==="
kubectl top nodes 2>/dev/null || echo "metrics-server not available"
echo ""

echo "=== OpenSearch Indices ==="
curl -s "http://localhost:9200/_cat/indices?format=json" | jq -c '.[] | {index:.index,docs:.["docs.count"],size:.["store.size"]}' 2>/dev/null || echo "OpenSearch not accessible"
echo ""

echo "=== Fluent Bit Pods ==="
kubectl get pods -n logging -l k8s-app=fluent-bit -o wide