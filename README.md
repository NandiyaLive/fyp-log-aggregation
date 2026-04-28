# A Decision Framework for Log Aggregation Strategy Selection in High-Duplication Kubernetes Workloads

Experimental framework for a final year research project evaluating three logging pipeline architectures to derive a decision framework for selecting optimal log aggregation strategies under varying duplication conditions.

## Research Question

Given a duplicate-heavy log workload, what storage reduction can be achieved at each layer of the Kubernetes logging pipeline for a given bound on acceptable information loss, and how can practitioners systematically select the appropriate aggregation strategy?

## Research Objective

Determine the best trade-off between storage reduction and information preservation in Kubernetes log aggregation, producing a decision framework that maps workload characteristics to optimal pipeline selection.

## Pipelines Evaluated

| Pipeline | Architecture | Aggregation Layer | Best For |
|:---|:---|:---|:---|
| **A (Baseline)** | Workload → Fluent Bit → OpenSearch | None | Reference comparison |
| **B (Edge)** | Workload → Fluent Bit → **Lua Filter** → OpenSearch | Collector (edge) | Cost-sensitive, fault-tolerant systems |
| **C (Index-Time)** | Workload → Fluent Bit → OpenSearch → **Upsert** | Storage (index-time) | Critical systems requiring guaranteed completeness |

## Decision Framework Output

From experimental results, practitioners can derive rules such as:

> For workloads with duplicate ratio >60%, index-time aggregation achieves >85% storage reduction with zero information loss, while edge aggregation achieves an additional 5–10% storage reduction at the cost of 1–3% information loss under failure.

## Workload Distribution

| Category | Duplicate Ratio | Count |
|:---|:---|:---|
| Low-dup | 0% – 30% | 33 |
| Med-dup | 30% – 70% | 40 |
| High-dup | 70% – 90% | 27 |
| **Total** | | **100** |

Each workload: 1,000,000 synthetic logs with deterministic seeding.

## Metrics

| Metric | Symbol | Definition |
|:---|:---|:---|
| Storage Reduction Ratio | SRR | 1 − (Storage_aggregated / Storage_baseline) |
| Information Preservation Ratio | IPR | Logs reconstructable / Logs sent |
| Compression Efficiency | CE | Total logs / Documents indexed |
| Failure Loss Rate | FLR | 1 − IPR under simulated collector crash |

## Repository Structure

```
├── configs/              # Kubernetes and Fluent Bit configurations
│   ├── opensearch-values.yaml
│   ├── dashboards-values.yaml
│   ├── fluent-bit-base.conf          # Pipeline A
│   ├── fluent-bit-pipeline-b.conf    # Pipeline B (Lua filter)
│   ├── fluent-bit-pipeline-c.conf    # Pipeline C (Upsert)
│   ├── fluent-bit-ds.yaml            # DaemonSet definition
│   ├── parsers.conf
│   ├── semantic_aggregate.lua        # Edge deduplication logic
│   └── generate_agg_id.lua           # Index-time ID generation
├── workloads/
│   ├── log_generator.py              # Synthetic log generator
│   └── Dockerfile
├── scripts/
│   ├── install_opensearch.sh         # One-time infrastructure setup
│   ├── build_workload.sh             # Build workload container image
│   ├── deploy_fluentbit.sh           # Deploy pipeline variant
│   ├── generate_workloads.py         # Generate 100 workload definitions
│   ├── run_experiment.sh             # Single experiment runner
│   └── run_all.sh                    # Full experiment matrix
└── analysis/
    └── analyze.py                    # Compute metrics, generate graphs
```

## Infrastructure

- **Platform:** DigitalOcean droplet (Ubuntu 24.04)
- **Kubernetes:** k3s single-node cluster
- **Log Storage:** OpenSearch (single-node)
- **Visualization:** OpenSearch Dashboards
- **Collector:** Fluent Bit 3.1 with custom Lua filters

## Quick Start

### Prerequisites

- DigitalOcean droplet: 8 vCPU, 16 GB RAM, 320 GB SSD
- Domain or static IP (for k3s TLS SAN)

### Server Setup (one-time, as root)

```bash
# Hardening: create user researcher, disable root SSH, configure UFW
# See thesis methodology for complete hardening procedure

# Install k3s
curl -sfL https://get.k3s.io | sh -s - server --disable traefik --write-kubeconfig-mode 644
```

### Experiment Setup (as researcher)

```bash
# Clone
git clone https://github.com/YOUR_USERNAME/fyp-log-aggregation.git
cd fyp-log-aggregation

# Runtime directories
mkdir -p results output

# Infrastructure
./scripts/install_opensearch.sh

# Workload image
./scripts/build_workload.sh

# Port forwards (in tmux/screen)
kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &
kubectl port-forward svc/dashboards-opensearch-dashboards 5601:5601 -n logging &
```

### Run Experiments

```bash
# Clean slate: fresh OpenSearch index per workload
./scripts/run_all.sh clean_slate

# No clean slate: cumulative index growth analysis
./scripts/run_all.sh no_clean_slate
```

### Analyze

```bash
python3 analysis/analyze.py
# Outputs: output/failure_impact.png, output/tradeoff_curve.png,
#          output/cumulative_no_clean_slate.png, output/comparison_table.md
```

## Key Results (Expected)

| Pipeline | High-Dup SRR | High-Dup IPR | Failure Sensitivity | Decision Rule |
|:---|:---|:---|:---|:---|
| Baseline (A) | 0% | 100% | None | Never optimal for dup >30% |
| Edge (B) | ~85–92% | ~97–99% | Loses 3–4% under crash | Use when cost dominates, failures rare |
| Index-Time (C) | ~85–89% | 100% | Zero loss guaranteed | Use when reliability is critical |

**Trade-off:** Edge aggregation achieves marginally higher storage reduction at the cost of bounded information loss during collector failure. Index-time aggregation guarantees zero loss with slightly lower savings. The decision framework maps these trade-offs to operational requirements.

## Graphs Generated

1. **Failure Impact Graph** — IPR under normal vs. failure conditions (answers: "Where does loss come from?")
2. **Trade-off Curve** — SRR vs. IPR scatter across all workloads (answers: "What are my options?")
3. **Storage Reduction vs. Duplicate Ratio** — Performance across duplication spectrum
4. **Cumulative Growth (No Clean Slate)** — Long-term storage growth comparison
