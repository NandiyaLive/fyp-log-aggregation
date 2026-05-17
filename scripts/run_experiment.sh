#!/bin/bash
# Run a single experiment: one pipeline against one workload.
# Usage: ./run_experiment.sh <A|B|C> <workload_id> <dup_ratio> <seed> [clean_slate:true|false]
set -euo pipefail

PIPELINE=${1:-}
WL_ID=${2:-}
DUP_RATIO=${3:-}
SEED=${4:-}
CLEAN_SLATE=${5:-true}

if [ -z "$PIPELINE" ] || [ -z "$WL_ID" ] || [ -z "$DUP_RATIO" ] || [ -z "$SEED" ]; then
    echo "Usage: $0 <A|B|C> <wl_id> <dup_ratio> <seed> [clean_slate]" >&2
    exit 1
fi

OS_URL="http://localhost:9200"
JOB_TIMEOUT=900       # seconds to wait for the workload Job to complete
INDEX_POLL_MAX=120    # poll iterations (x10s) waiting for indexing to settle

# Robust GET against OpenSearch: retries, and never aborts the script.
os_get() {
    local path=$1 body i
    for i in 1 2 3 4 5; do
        body=$(curl -s --max-time 30 "${OS_URL}${path}" 2>/dev/null || true)
        if [ -n "$body" ]; then
            echo "$body"
            return 0
        fi
        sleep 5
    done
    echo ""
}

get_count() {
    os_get "/$1/_count" | jq -r '.count // 0' 2>/dev/null || echo 0
}

get_index_total() {
    os_get "/$1/_stats/indexing" | jq -r '._all.total.indexing.index_total // 0' 2>/dev/null || echo 0
}

# Wait until Fluent Bit has finished indexing the current workload.
# Tracks the index-operation counter, not the document count: pipelines B
# (edge dedup) and C (upsert) barely change the doc count, but every record
# Fluent Bit forwards still registers as an index operation. After a warm-up
# grace period, a plateau in index_total means indexing has drained.
INDEX_WARMUP_POLLS=6
INDEX_STABLE_POLLS=4
wait_for_indexing() {
    local index=$1 prev=-1 stable=0 i total
    for i in $(seq 1 "$INDEX_POLL_MAX"); do
        sleep 10
        total=$(get_index_total "$index")
        echo "  [poll $i] $index index_total=$total"
        if [ "$i" -gt "$INDEX_WARMUP_POLLS" ] \
           && [ "$total" -gt 0 ] \
           && [ "$total" -eq "$prev" ] 2>/dev/null; then
            stable=$((stable + 1))
            if [ "$stable" -ge "$INDEX_STABLE_POLLS" ]; then
                echo "  indexing settled (index_total=$total)"
                return 0
            fi
        else
            stable=0
        fi
        prev=$total
    done
    echo "  WARN: indexing for '$index' did not settle within $((INDEX_POLL_MAX * 10))s"
}

# Always remove the previous workload Job first: a Job's pod template is
# immutable, so re-applying with new args (dup_ratio/seed) would otherwise
# fail. Removing the pod also clears its container log file.
kubectl delete job log-workload -n default --ignore-not-found=true

# Clean slate: fresh OpenSearch indices and a fresh Fluent Bit position DB.
if [ "$CLEAN_SLATE" = "true" ]; then
    echo "=== CLEAN SLATE ==="
    curl -s -X DELETE "${OS_URL}/_all?expand_wildcards=all&allow_no_indices=true" >/dev/null 2>&1 || true
    curl -s -X POST "${OS_URL}/_cache/clear" >/dev/null 2>&1 || true
    kubectl rollout restart daemonset fluent-bit -n logging
    kubectl rollout status daemonset fluent-bit -n logging --timeout=180s
    sleep 30
fi

# Deploy the workload Job.
cat <<JOBEOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: log-workload
  namespace: default
spec:
  backoffLimit: 0
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
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2"
            memory: "1Gi"
        volumeMounts:
        - name: shared-logs
          mountPath: /tmp
      - name: emitter
        image: busybox:1.36
        command: ["/bin/sh", "-c"]
        args:
        - |
          while [ ! -f /tmp/workload.log ]; do sleep 1; done
          cat /tmp/workload.log
        resources:
          requests:
            cpu: "100m"
            memory: "32Mi"
          limits:
            cpu: "1"
            memory: "64Mi"
        volumeMounts:
        - name: shared-logs
          mountPath: /tmp
      volumes:
      - name: shared-logs
        emptyDir: {}
JOBEOF

echo "Waiting for workload Job to complete (timeout ${JOB_TIMEOUT}s)..."
kubectl wait --for=condition=complete job/log-workload -n default --timeout=${JOB_TIMEOUT}s

# Collect metrics.
INDEX_NAME="logs"
[ "$PIPELINE" = "B" ] && INDEX_NAME="logs-edge"
[ "$PIPELINE" = "C" ] && INDEX_NAME="logs-index"

echo "Waiting for Fluent Bit to finish indexing into '$INDEX_NAME'..."
wait_for_indexing "$INDEX_NAME"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="results/${PIPELINE}_wl${WL_ID}_${TIMESTAMP}"
mkdir -p "$RESULT_DIR"

DOC_COUNT=$(get_count "$INDEX_NAME")
STATS=$(os_get "/${INDEX_NAME}/_stats/store")
TOTAL_STATS=$(os_get "/_stats/store")
STORAGE=$(echo "$STATS" | jq -r '._all.total.store.size_in_bytes // 0' 2>/dev/null || echo 0)
TOTAL_STORAGE=$(echo "$TOTAL_STATS" | jq -r '._all.total.store.size_in_bytes // 0' 2>/dev/null || echo 0)

echo "1000000" > "$RESULT_DIR/N.txt"
echo "$DOC_COUNT" > "$RESULT_DIR/M.txt"
echo "$STATS" > "$RESULT_DIR/stats.json"
echo "$STORAGE" > "$RESULT_DIR/storage.txt"
echo "$TOTAL_STORAGE" > "$RESULT_DIR/total_storage.txt"

mkdir -p results
echo "${PIPELINE},${WL_ID},${DUP_RATIO},${SEED},1000000,${DOC_COUNT},${STORAGE},${TOTAL_STORAGE},${TIMESTAMP}" >> results/experiments.csv

echo "Done: $RESULT_DIR | Docs=$DOC_COUNT | Storage=$STORAGE | TotalStorage=$TOTAL_STORAGE"
