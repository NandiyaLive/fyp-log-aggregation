#!/bin/bash
# Run full experiment matrix
# Usage: ./run_all.sh <clean_slate|no_clean_slate>

set -e
MODE=${1:-clean_slate}
mkdir -p results

# Auto-generate workloads if missing
if [ ! -f "workloads/workloads.json" ]; then
    echo "workloads.json not found. Generating..."
    python3 scripts/generate_workloads.py
fi

CSV="results/experiments_${MODE}.csv"
echo "pipeline,workload_id,dup_ratio,seed,N,M,storage,total_storage,timestamp" > "$CSV"

WORKLOADS=$(cat workloads/workloads.json | jq -c '.[]')

for pipeline in A B C; do
    echo "=== PIPELINE $PIPELINE ($MODE) ==="

    ./scripts/deploy_fluentbit.sh "$pipeline"

    if [ "$MODE" = "no_clean_slate" ]; then
        ./scripts/run_experiment.sh "$pipeline" 0 0.0 42 true
    fi

    echo "$WORKLOADS" | while read -r wl; do
        id=$(echo "$wl" | jq '.id')
        ratio=$(echo "$wl" | jq -r '.dup_ratio')
        seed=$(echo "$wl" | jq -r '.seed')

        echo "Running WL-$id (dup=$ratio)"

        if [ "$MODE" = "clean_slate" ]; then
            ./scripts/run_experiment.sh "$pipeline" "$id" "$ratio" "$seed" true
        else
            ./scripts/run_experiment.sh "$pipeline" "$id" "$ratio" "$seed" false
        fi

        tail -1 results/experiments.csv >> "$CSV"
        sleep 10
    done
done

echo "=== $MODE EXPERIMENTS COMPLETE ==="
