#!/bin/bash
# Run a single experiment: one pipeline against one workload.
# Usage: ./run_experiment.sh <A|B|C> <workload_id> <dup_ratio> <seed> [clean_slate:true|false] [fail:true|false]
#
# fail=true injects a real collector crash: once indexing reaches ~50% it
# deletes the Fluent Bit pod, then lets the DaemonSet bring it back. Whatever
# the edge buffer had not yet forwarded is genuinely lost, so the measured
# reconstructed count (and hence IPR/FLR) reflects an empirical failure.
set -euo pipefail

PIPELINE=${1:-}
WL_ID=${2:-}
DUP_RATIO=${3:-}
SEED=${4:-}
CLEAN_SLATE=${5:-true}
FAIL=${6:-false}

if [ -z "$PIPELINE" ] || [ -z "$WL_ID" ] || [ -z "$DUP_RATIO" ] || [ -z "$SEED" ]; then
    echo "Usage: $0 <A|B|C> <wl_id> <dup_ratio> <seed> [clean_slate] [fail]" >&2
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

# Sum of the per-document `count` field = number of original log lines the
# index claims to represent (the reconstructed volume). Pipeline A has no
# `count` field, so this returns 0 there and the caller falls back to doc count.
get_reconstructed() {
    local body i out
    for i in 1 2 3; do
        out=$(curl -s --max-time 30 -H 'Content-Type: application/json' \
            -X POST "${OS_URL}/$1/_search?size=0" \
            -d '{"aggs":{"recon":{"sum":{"field":"count"}}}}' 2>/dev/null || true)
        body=$(echo "$out" | jq -r '.aggregations.recon.value // 0' 2>/dev/null || echo 0)
        if [ -n "$body" ] && [ "$body" != "null" ]; then echo "$body"; return 0; fi
        sleep 3
    done
    echo 0
}

# Force a single segment and refresh so store-size and counts are stable and
# comparable across pipelines (upsert churn otherwise leaves deleted-doc bloat
# that makes index-time look far larger than it really is).
settle_index() {
    curl -s --max-time 120 -X POST "${OS_URL}/$1/_forcemerge?max_num_segments=1&wait_for_completion=true&only_expunge_deletes=false" >/dev/null 2>&1 || true
    curl -s --max-time 30 -X POST "${OS_URL}/$1/_refresh" >/dev/null 2>&1 || true
    sleep 5
}

# Background failure injector: wait until indexing crosses ~half the workload,
# then delete the Fluent Bit pod once.
TOTAL_LOGS=1000000
inject_failure() {
    local index=$1 threshold=$((TOTAL_LOGS / 2)) i total
    for i in $(seq 1 "$INDEX_POLL_MAX"); do
        sleep 5
        total=$(get_index_total "$index")
        if [ "$total" -ge "$threshold" ] 2>/dev/null; then
            echo "  [FAIL-INJECT] index_total=$total >= $threshold : killing Fluent Bit pod"
            kubectl delete pod -l k8s-app=fluent-bit -n logging --grace-period=0 --force >/dev/null 2>&1 || true
            return 0
        fi
    done
    echo "  [FAIL-INJECT] threshold never reached; no crash injected"
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

# Optional crash injection runs concurrently with indexing.
if [ "$FAIL" = "true" ]; then
    echo "Failure mode ON: will crash Fluent Bit at ~50% indexed."
    inject_failure "$INDEX_NAME" &
    FAIL_PID=$!
fi

echo "Waiting for Fluent Bit to finish indexing into '$INDEX_NAME'..."
wait_for_indexing "$INDEX_NAME"
[ -n "${FAIL_PID:-}" ] && wait "$FAIL_PID" 2>/dev/null || true

# Stabilize storage and counts before measuring.
settle_index "$INDEX_NAME"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="results/${PIPELINE}_wl${WL_ID}_${TIMESTAMP}"
mkdir -p "$RESULT_DIR"

DOC_COUNT=$(get_count "$INDEX_NAME")
STATS=$(os_get "/${INDEX_NAME}/_stats/store")
TOTAL_STATS=$(os_get "/_stats/store")
STORAGE=$(echo "$STATS" | jq -r '._all.total.store.size_in_bytes // 0' 2>/dev/null || echo 0)
TOTAL_STORAGE=$(echo "$TOTAL_STATS" | jq -r '._all.total.store.size_in_bytes // 0' 2>/dev/null || echo 0)

# Reconstructed = original lines the index represents. Pipeline A keeps every
# line as its own doc (no count field), so reconstructed == doc count there.
RECON=$(get_reconstructed "$INDEX_NAME")
RECON=${RECON%.*}
if [ "${RECON:-0}" = "0" ]; then RECON=$DOC_COUNT; fi

echo "$TOTAL_LOGS" > "$RESULT_DIR/N.txt"
echo "$DOC_COUNT" > "$RESULT_DIR/M.txt"
echo "$STATS" > "$RESULT_DIR/stats.json"
echo "$STORAGE" > "$RESULT_DIR/storage.txt"
echo "$TOTAL_STORAGE" > "$RESULT_DIR/total_storage.txt"
echo "$RECON" > "$RESULT_DIR/reconstructed.txt"

mkdir -p results
echo "${PIPELINE},${WL_ID},${DUP_RATIO},${SEED},${TOTAL_LOGS},${DOC_COUNT},${STORAGE},${TOTAL_STORAGE},${RECON},${FAIL},${TIMESTAMP}" >> results/experiments.csv

echo "Done: $RESULT_DIR | Docs=$DOC_COUNT | Storage=$STORAGE | Recon=$RECON | Failed=$FAIL"
