#!/bin/bash
# Run full experiment matrix
# Usage: ./run_all.sh <clean_slate|no_clean_slate>

set -e
MODE=${1:-clean_slate}

echo "=== Checking prerequisites ==="

# Check jq
if ! command -v jq &> /dev/null; then
    echo "jq not found. Installing..."
    sudo apt-get update && sudo apt-get install -y jq
fi

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl not found. Install k3s first."
    exit 1
fi

# Check k3s running
if ! kubectl cluster-info &> /dev/null; then
    echo "ERROR: k3s not running. Start k3s first."
    exit 1
fi

# Create logging namespace if not exists
kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -

# Build workload image if not exists
if ! kubectl get pods -n default 2>/dev/null | grep -q "workload-generator" 2>/dev/null || \
   ! k3s ctr images list 2>/dev/null | grep -q "workload-generator"; then
    echo "Building workload image..."
    ./scripts/build_workload.sh
fi

# Check OpenSearch port-forward (start if needed)
if ! curl -s http://localhost:9200 > /dev/null 2>&1; then
    echo "OpenSearch port-forward not running. Starting in background..."
    kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &
    sleep 5
    for i in {1..30}; do
        if curl -s http://localhost:9200 > /dev/null 2>&1; then
            echo "OpenSearch is ready"
            break
        fi
        sleep 2
    done
fi

# Verify OpenSearch is accessible
if ! curl -s http://localhost:9200 > /dev/null 2>&1; then
    echo "ERROR: OpenSearch not accessible at localhost:9200"
    echo "Run: kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging"
    exit 1
fi

echo "=== Prerequisites OK ==="
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

    # Read workloads into array to avoid subshell issues
    mapfile -t WL_ARRAY < <(jq -c '.[]' workloads/workloads.json)

    for wl in "${WL_ARRAY[@]}"; do
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