#!/bin/bash
# Run a single experiment: one pipeline against one workload.
# Usage: ./run_experiment.sh <A|B|C> <workload_id> <dup_ratio> <seed> [clean_slate:true|false] [fail:true|false]
#
# fail=true injects a real collector crash: once indexing reaches ~50% it
# deletes the Fluent Bit pod, then lets the DaemonSet bring it back. Whatever
# the edge buffer had not yet forwarded is genuinely lost, so the measured
# reconstructed count (and hence IPR/FLR) reflects an empirical failure.
set -euo pipefail
cd "$(dirname "$0")/.."

PIPELINE=${1:-}
WL_ID=${2:-}
DUP_RATIO=${3:-}
SEED=${4:-}
CLEAN_SLATE=${5:-true}
FAIL=${6:-false}
# Backward compat: legacy callers pass "true" meaning Fluent Bit kill.
[ "$FAIL" = "true" ] && FAIL=fb

if [ -z "$PIPELINE" ] || [ -z "$WL_ID" ] || [ -z "$DUP_RATIO" ] || [ -z "$SEED" ]; then
    echo "Usage: $0 <A|B|C> <wl_id> <dup_ratio> <seed> [clean_slate] [fail]" >&2
    exit 1
fi

OS_URL="http://localhost:9200"
JOB_TIMEOUT=900       # seconds to wait for the workload Job to complete
INDEX_POLL_MAX=200    # poll iterations (x3s) waiting for indexing to settle

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
}

# Background failure injector: wait until indexing crosses ~half the workload,
# then kill the chosen target once. target=fb (Fluent Bit, edge-loss) or
# os (OpenSearch, sink-loss).
TOTAL_LOGS=1000000
inject_failure() {
    local index=$1 target=${2:-fb} threshold=$((TOTAL_LOGS / 2)) i total
    for i in $(seq 1 "$INDEX_POLL_MAX"); do
        sleep 5
        total=$(get_index_total "$index")
        case "$total" in
            ''|*[!0-9]*) total=0 ;;
        esac
        if [ "$total" -ge "$threshold" ] 2>/dev/null; then
            case "$target" in
                fb)
                    echo "  [FAIL-INJECT] index_total=$total >= $threshold : killing Fluent Bit pod"
                    kubectl delete pod -l k8s-app=fluent-bit -n logging --grace-period=0 --force >/dev/null 2>&1 || true
                    ;;
                os)
                    echo "  [FAIL-INJECT] index_total=$total >= $threshold : killing OpenSearch pod"
                    kubectl delete pod opensearch-cluster-master-0 -n logging --grace-period=0 --force >/dev/null 2>&1 || true
                    # Block until cluster recovers so wait_for_indexing does not
                    # mistake the downtime for a real plateau.
                    local j
                    for j in $(seq 1 60); do
                        if curl -sf --max-time 5 "${OS_URL}/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null 2>&1; then
                            echo "  [FAIL-INJECT] OpenSearch back to yellow after ${j} poll(s)"
                            break
                        fi
                        sleep 5
                    done
                    ;;
                *)
                    echo "  [FAIL-INJECT] unknown target '$target'; skipping"
                    ;;
            esac
            return 0
        fi
    done
    echo "  [FAIL-INJECT] threshold never reached; no crash injected"
}

# Wait until Fluent Bit has finished indexing the current workload.
#
# Two completion signals, in priority order:
#   1. Fast path  -- the index-operation counter (index_total) reaches the
#      expected volume. index_total is monotonic and counts every record
#      Fluent Bit forwards, so it lands near TOTAL_LOGS for every pipeline
#      regardless of dedup (B/C barely change the doc count). This is the
#      authoritative "all lines delivered" signal.
#   2. Plateau    -- a long flat stretch in the doc count. Used only when the
#      fast path never fires: failure runs lose data (so index_total stops
#      short of target) and an OpenSearch pod restart resets index_total to 0.
#      Doc count is computed from the index itself, so it survives restart.
#
# The plateau window must be wider than Fluent Bit's burst gaps: it forwards in
# bursts with >9s idle stretches between flushes, so a short window mistakes an
# inter-flush gap for completion and stops mid-stream.
COMPLETION_RATIO_PCT=99      # treat index_total >= 99% of TOTAL_LOGS as done
INDEX_WARMUP_POLLS=3
INDEX_STABLE_POLLS=10        # x3s = 30s flat doc count before declaring plateau
wait_for_indexing() {
    local index=$1 pipeline=${2:-A} prev=-1 stable=0 i docs ops
    local target=$((TOTAL_LOGS * COMPLETION_RATIO_PCT / 100))
    for i in $(seq 1 "$INDEX_POLL_MAX"); do
        sleep 3
        docs=$(get_count "$index")
        ops=$(get_index_total "$index")
        # Coerce empty / non-numeric output to 0 so the integer tests are safe.
        case "$docs" in ''|*[!0-9]*) docs=0 ;; esac
        case "$ops"  in ''|*[!0-9]*) ops=0  ;; esac
        echo "  [poll $i] $index ($pipeline) docs=$docs ops=$ops"
        # Fast path: forwarding actually completed.
        if [ "$ops" -ge "$target" ] 2>/dev/null; then
            echo "  indexing complete (ops=$ops >= target=$target)"
            return 0
        fi
        # Fallback: long doc-count plateau (failure-mode loss / ops reset).
        if [ "$i" -gt "$INDEX_WARMUP_POLLS" ] \
           && [ "$docs" -gt 0 ] \
           && [ "$docs" -eq "$prev" ] 2>/dev/null; then
            stable=$((stable + 1))
            if [ "$stable" -ge "$INDEX_STABLE_POLLS" ]; then
                echo "  indexing settled via plateau (docs=$docs ops=$ops)"
                return 0
            fi
        else
            stable=0
        fi
        prev=$docs
    done
    echo "  WARN: indexing for '$index' did not settle within $((INDEX_POLL_MAX * 3))s"
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
    sleep 5
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
# FAIL values: false | fb (Fluent Bit kill) | os (OpenSearch kill).
if [ "$FAIL" = "fb" ] || [ "$FAIL" = "os" ]; then
    echo "Failure mode ON ($FAIL): will crash target at ~50% indexed."
    inject_failure "$INDEX_NAME" "$FAIL" &
    FAIL_PID=$!
fi

echo "Waiting for Fluent Bit to finish indexing into '$INDEX_NAME'..."
wait_for_indexing "$INDEX_NAME" "$PIPELINE"
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
