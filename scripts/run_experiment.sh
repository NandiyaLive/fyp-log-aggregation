#!/bin/bash
# Usage: ./run_experiment.sh <A|B|C> <workload_id> <dup_ratio> <seed> [clean_slate:true|false]

set -e
PIPELINE=$1
WL_ID=$2
DUP_RATIO=$3
SEED=$4
CLEAN_SLATE=${5:-true}

[ -z "$PIPELINE" ] && { echo "Usage: $0 <A|B|C> <wl_id> <dup_ratio> <seed> [clean_slate]"; exit 1; }

# Clean slate if requested
if [ "$CLEAN_SLATE" = "true" ]; then
    echo "=== CLEAN SLATE ==="
    curl -s -X DELETE "http://localhost:9200/_all?expand_wildcards=all&allow_no_indices=true" || true
    curl -s -X POST "http://localhost:9200/_cache/clear" || true
    kubectl delete job log-workload -n default --ignore-not-found=true
    kubectl rollout restart daemonset fluent-bit -n logging
    kubectl rollout status daemonset fluent-bit -n logging --timeout=120s
    sleep 30

    idx=$(curl -s "http://localhost:9200/_cat/indices?format=json" | jq length)
    docs=$(curl -s "http://localhost:9200/_count" | jq '.count')
    echo "Indices: $idx | Docs: $docs"
fi

# Deploy workload
cat << JOBEOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: log-workload
  namespace: default
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: generator
        image: workload-generator:latest
        imagePullPolicy: IfNotPresent
        args:
        - --total=1000000
        - --dup-ratio=${DUP_RATIO}
        - --output=/tmp/workload.log
        - --seed=${SEED}
        volumeMounts:
        - name: shared-logs
          mountPath: /tmp
      - name: emitter
        image: busybox:1.36
        command: ["/bin/sh", "-c"]
        args:
        - |
          while [ ! -f /tmp/workload.log ]; do sleep 1; done
          while IFS= read -r line; do
            echo "\$line"
          done < /tmp/workload.log
        volumeMounts:
        - name: shared-logs
          mountPath: /tmp
      volumes:
      - name: shared-logs
        emptyDir: {}
JOBEOF

kubectl wait --for=condition=complete job/log-workload -n default --timeout=600s
sleep 60

# Collect metrics
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="results/${PIPELINE}_wl${WL_ID}_${TIMESTAMP}"
mkdir -p "$RESULT_DIR"

INDEX_NAME="logs"
[ "$PIPELINE" = "B" ] && INDEX_NAME="logs-edge"
[ "$PIPELINE" = "C" ] && INDEX_NAME="logs-index"

echo "1000000" > "$RESULT_DIR/N.txt"
DOC_COUNT=$(curl -s "http://localhost:9200/${INDEX_NAME}/_count" | jq '.count')
echo "$DOC_COUNT" > "$RESULT_DIR/M.txt"

STATS=$(curl -s "http://localhost:9200/${INDEX_NAME}/_stats/store")
echo "$STATS" > "$RESULT_DIR/stats.json"
STORAGE=$(echo "$STATS" | jq '.indices[keys[0]].total.store.size_in_bytes')
echo "$STORAGE" > "$RESULT_DIR/storage.txt"

TOTAL_STORAGE=$(curl -s "http://localhost:9200/_stats/store" | jq '.indices[keys[0]].total.store.size_in_bytes')
echo "$TOTAL_STORAGE" > "$RESULT_DIR/total_storage.txt"

echo "$PIPELINE,$WL_ID,$DUP_RATIO,$SEED,1000000,$DOC_COUNT,$STORAGE,$TOTAL_STORAGE,$TIMESTAMP" >> results/experiments.csv

echo "Done: $RESULT_DIR | Docs=$DOC_COUNT | Storage=$STORAGE"
