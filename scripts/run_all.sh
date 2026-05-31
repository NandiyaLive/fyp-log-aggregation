#!/bin/bash
# Run the full experiment matrix (pipelines A, B, C against every workload).
# A single failed experiment is logged and skipped; the matrix continues.
# Usage: ./scripts/run_all.sh <clean_slate|no_clean_slate>
set -uo pipefail
cd "$(dirname "$0")/.."

MODE=${1:-clean_slate}

if [ "$MODE" != "clean_slate" ] && [ "$MODE" != "no_clean_slate" ] && [ "$MODE" != "failure" ]; then
    echo "Usage: $0 <clean_slate|no_clean_slate|failure>" >&2
    exit 1
fi

# failure mode: same as clean_slate but injects a real collector crash into
# every run so the analysis can compute empirical FLR.
INJECT_FAIL=false
[ "$MODE" = "failure" ] && INJECT_FAIL=true

# Sanity check: OpenSearch must be reachable via the port-forward.
if ! curl -s --max-time 10 http://localhost:9200 > /dev/null 2>&1; then
    echo "ERROR: OpenSearch not accessible at localhost:9200" >&2
    echo "Start the port-forward first:" >&2
    echo "  kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &" >&2
    exit 1
fi

mkdir -p results

# Auto-generate workloads if missing.
if [ ! -f "workloads/workloads.json" ]; then
    echo "workloads.json not found. Generating..."
    python3 scripts/generate_workloads.py
fi

CSV="results/experiments_${MODE}.csv"
FAILLOG="results/failures_${MODE}.log"
echo "pipeline,workload_id,dup_ratio,seed,N,M,storage,total_storage,reconstructed,failed,timestamp" > "$CSV"
: > "$FAILLOG"

# Run one experiment; append its result row on success, log it on failure.
run_one() {
    local pipeline=$1 id=$2 ratio=$3 seed=$4 clean=$5 fail=${6:-false}
    local before after
    before=$([ -f results/experiments.csv ] && wc -l < results/experiments.csv || echo 0)
    if ./scripts/run_experiment.sh "$pipeline" "$id" "$ratio" "$seed" "$clean" "$fail"; then
        after=$([ -f results/experiments.csv ] && wc -l < results/experiments.csv || echo 0)
        if [ "$after" -gt "$before" ]; then
            tail -1 results/experiments.csv >> "$CSV"
        else
            echo "pipeline=$pipeline wl=$id : completed but wrote no result row" >> "$FAILLOG"
        fi
    else
        echo "pipeline=$pipeline wl=$id : run_experiment.sh exited non-zero" >> "$FAILLOG"
        echo "!!! experiment failed (pipeline=$pipeline wl=$id) - continuing"
    fi
}

for pipeline in A B C; do
    echo "=== PIPELINE $pipeline ($MODE) ==="

    if ! ./scripts/deploy_fluentbit.sh "$pipeline"; then
        echo "!!! deploy_fluentbit.sh failed for pipeline $pipeline - skipping pipeline"
        echo "pipeline=$pipeline : deploy_fluentbit.sh failed" >> "$FAILLOG"
        continue
    fi

    # no_clean_slate: reset OpenSearch + Fluent Bit once, then accumulate.
    if [ "$MODE" = "no_clean_slate" ]; then
        run_one "$pipeline" 0 0.0 42 true
    fi

    mapfile -t WL_ARRAY < <(jq -c '.[]' workloads/workloads.json)
    for wl in "${WL_ARRAY[@]}"; do
        id=$(echo "$wl" | jq -r '.id')
        ratio=$(echo "$wl" | jq -r '.dup_ratio')
        seed=$(echo "$wl" | jq -r '.seed')
        echo "--- WL-$id (pipeline $pipeline, dup=$ratio) ---"

        if [ "$MODE" = "no_clean_slate" ]; then
            run_one "$pipeline" "$id" "$ratio" "$seed" false false
        else
            # clean_slate and failure both reset per workload; failure also
            # injects a mid-stream collector crash.
            run_one "$pipeline" "$id" "$ratio" "$seed" true "$INJECT_FAIL"
        fi
        sleep 10
    done
done

FAILS=$(wc -l < "$FAILLOG" | tr -d ' ')
echo "=== $MODE EXPERIMENTS COMPLETE ==="
echo "Results: $CSV"
if [ "$FAILS" -gt 0 ]; then
    echo "WARNING: $FAILS experiment(s) failed - see $FAILLOG"
fi
