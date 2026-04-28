#!/bin/bash
# Usage: ./deploy_fluentbit.sh <A|B|C>
# Deploys Fluent Bit DaemonSet with selected pipeline config

set -e
PIPELINE=${1:-A}

case $PIPELINE in
    A)
        CONFIG="configs/fluent-bit-base.conf"
        EXTRA=""
        ;;
    B)
        CONFIG="configs/fluent-bit-pipeline-b.conf"
        EXTRA="--from-file=semantic_aggregate.lua=configs/semantic_aggregate.lua"
        ;;
    C)
        CONFIG="configs/fluent-bit-pipeline-c.conf"
        EXTRA="--from-file=generate_agg_id.lua=configs/generate_agg_id.lua"
        ;;
    *)
        echo "Usage: $0 <A|B|C>"
        exit 1
        ;;
esac

# Create ConfigMap from repo files
kubectl create configmap fluent-bit-config \
    --from-file=fluent-bit.conf="$CONFIG" \
    --from-file=parsers.conf=configs/parsers.conf \
    $EXTRA \
    -n logging --dry-run=client -o yaml | kubectl apply -f -

# Deploy DaemonSet from repo file
kubectl apply -f configs/fluent-bit-ds.yaml -n logging
kubectl rollout status daemonset fluent-bit -n logging --timeout=120s

echo "Pipeline $PIPELINE deployed"
