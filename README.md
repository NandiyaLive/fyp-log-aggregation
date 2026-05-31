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

### What `dup_ratio` controls (the core invariant)

The pipelines deduplicate on a **normalized template signature**
(`level | component | message` with numbers→`{NUM}`, IPs→`{IP}`, UUIDs→`{UUID}`,
quoted strings→`{STR}`). Storage reduction is therefore driven by the number of
**distinct signatures**, not by byte-identical lines. The generator makes
`dup_ratio` (`r`) control exactly that quantity:

```
distinct events U = round(N · (1 − r))      → one indexed doc per signature
theoretical SRR   = 1 − U/N = r             → SRR is a direct function of r
compression eff.  = N / U   = 1 / (1 − r)
```

Each distinct event gets a unique, normalization-surviving `entity` token, so
its signature is unique; repeats (Zipf-biased) reuse an existing signature.
This is the property the old generator lacked — there, all 1M lines collapsed
to ~388 signatures regardless of `r`, so SRR was flat and the framework had no
signal. The contract is verified empirically (distinct signatures == `N·(1−r)`
at every ratio).

## Metrics (all measured, none hardcoded)

| Metric | Symbol | Definition |
|:---|:---|:---|
| Storage Reduction Ratio | SRR | 1 − (Storage_aggregated / Storage_baseline), real bytes after force-merge |
| Theoretical SRR | SRR* | `dup_ratio` — the reduction a perfect deduper achieves (reference line) |
| Information Preservation Ratio | IPR | `reconstructed / N` = sum of per-doc `count` field ÷ original lines |
| Compression Efficiency | CE | Total logs N / Documents indexed M |
| Failure Loss Rate | FLR | IPR_normal − IPR_failure, from a run with a real collector crash |

Each aggregated document carries a `count` field (cumulative occurrences of its
signature). Pipeline B (edge) re-emits the count only when it grows by
`FB_EMIT_EPS` (default 2%), upserting by signature — so it forwards far fewer
records (edge reduction) at the cost of a small, bounded count lag, and loses
its in-memory tail on a crash. Pipeline C (index-time) forwards every record and
upserts by signature, so counts are exact and crash exposure is minimal.

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
│   ├── deploy_fluentbit.sh           # Deploy a pipeline variant
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
- **Visualization:** OpenSearch Dashboards (optional)
- **Collector:** Fluent Bit 3.1 with custom Lua filters

The configs are tuned to run on a **4 vCPU / 8 GB RAM / 160 GB disk** droplet
(OpenSearch is capped at a 4 GiB container limit and a 2 GiB JVM heap). More
resources will run faster but are not required.

---

# Running the Experiment

Run the steps below **in order**. Steps 1–6 are one-time setup; steps 7–9 are
the experiment itself. All commands are run from the repository root unless
stated otherwise.

## 1. Provision the droplet and install host prerequisites

As root on a fresh Ubuntu 24.04 droplet:

```bash
# Hardening (create a non-root user, disable root SSH, configure UFW) —
# see the thesis methodology for the full procedure.

apt-get update
apt-get install -y jq git docker.io
```

## 2. Install k3s

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --write-kubeconfig-mode 644 \
  --kubelet-arg=container-log-max-size=2Gi \
  --kubelet-arg=container-log-max-files=2
```

The large `container-log-max-size` is important: each workload emits ~400 MB of
container logs at once. With the default 10 MiB rotation, most of it would be
rotated away before Fluent Bit could read it, undercounting indexed documents.

Make `kubectl` use the k3s kubeconfig (add to `~/.bashrc` to persist):

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

## 3. Clone the repo and install Python dependencies

```bash
git clone <repo-url> fyp-log-aggregation
cd fyp-log-aggregation

pip3 install numpy pandas matplotlib tabulate
mkdir -p results output
```

`tabulate` is required by `analysis/analyze.py` for Markdown table output.

## 4. Install OpenSearch (and optionally Dashboards)

```bash
# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add opensearch https://opensearch-project.github.io/helm-charts/
helm repo update

# Namespace
kubectl create namespace logging

# OpenSearch
helm install opensearch opensearch/opensearch \
  -f configs/opensearch-values.yaml \
  -n logging
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/component=opensearch \
  -n logging --timeout=600s
```

Dashboards are **optional** (used only for manual inspection, not by the
experiment). Skip on a memory-constrained droplet:

```bash
helm install dashboards opensearch/opensearch-dashboards \
  -f configs/dashboards-values.yaml \
  -n logging
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=opensearch-dashboards \
  -n logging --timeout=600s
```

## 5. Build and import the workload image

The workload generator runs as a container; build it and import it into the
k3s containerd image store:

```bash
cd workloads
docker build -t workload-generator:latest .
docker save workload-generator:latest | sudo k3s ctr images import -
cd ..
```

## 6. Generate the workload definitions

```bash
python3 scripts/generate_workloads.py
```

This writes `workloads/workloads.json` (100 workload definitions). `run_all.sh`
also generates this automatically if it is missing.

## 7. Start the OpenSearch port-forward

`run_all.sh` talks to OpenSearch on `localhost:9200`. Start the port-forward in
a `tmux`/`screen` session and leave it running:

```bash
kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &
```

Optionally, for Dashboards:

```bash
kubectl port-forward svc/dashboards-opensearch-dashboards 5601:5601 -n logging &
```

## 8. Run the experiment matrix

Run **both** modes — the analysis step needs both result files. Each mode runs
3 pipelines × 100 workloads and takes several hours; run inside `tmux`/`screen`.

```bash
# Clean slate: a fresh OpenSearch index per workload (normal-path metrics)
./scripts/run_all.sh clean_slate

# No clean slate: cumulative index growth analysis
./scripts/run_all.sh no_clean_slate

# Failure: clean slate + a real collector crash injected at ~50% indexed,
# so FLR is measured empirically (needed for the failure-impact figure).
./scripts/run_all.sh failure
```

A failed individual experiment is logged to `results/failures_<mode>.log` and
skipped; the matrix continues. Results are written to
`results/experiments_<mode>.csv` with columns
`pipeline,workload_id,dup_ratio,seed,N,M,storage,total_storage,reconstructed,failed,timestamp`.

> **Failure-mode note:** the crash is injected by deleting the Fluent Bit pod.
> Whatever the edge buffer (pipeline B) had not yet forwarded is lost, which is
> the effect under test. After restart the DaemonSet resumes tailing; if you
> see IPR recover to ~1.0 under failure, the collector re-read the log from the
> start — pin the tail position on a `hostPath` volume (instead of the
> ephemeral `/tmp/fluent-bit-kube.db`) so the failure is a clean, permanent
> loss. Verify a failure run actually shows `reconstructed < N` for B.

## 9. Analyze

```bash
python3 analysis/analyze.py
```

`analyze.py` processes each mode independently — it analyzes whichever of
`experiments_clean_slate.csv` / `experiments_no_clean_slate.csv` are present,
so it can be run after one mode or both.

Outputs in `output/`:

| File | Mode | Content |
|:---|:---|:---|
| `failure_impact.png` | clean slate | IPR, normal vs. failure |
| `tradeoff_curve.png` | clean slate | SRR vs. IPR scatter |
| `srr_vs_dupratio.png` | clean slate | Storage reduction vs. duplicate ratio |
| `comparison_table.md` / `.csv` | clean slate | Per-pipeline / per-category metrics |
| `cumulative_no_clean_slate.png` | no clean slate | Cumulative storage growth |
| `cumulative_summary.md` / `.csv` | no clean slate | Final cumulative docs, storage, SRR |

---

## Key Results (Expected)

With the redesigned setup, SRR now tracks `dup_ratio`: at high dup (`r≈0.9`)
both aggregating pipelines approach ~90% storage reduction; at low dup they
correctly show little reduction. The interesting findings are the **gap** from
the theoretical line (per-document and segment overhead) and the
**failure split** between edge and index-time.

| Pipeline | High-Dup SRR | High-Dup IPR (normal) | IPR (under crash) | Decision Rule |
|:---|:---|:---|:---|:---|
| Baseline (A) | ~0% | 100% | 100% | Never optimal for dup >30% |
| Edge (B) | ≈ `r` (≈90%) | ~99.9% (bounded by `FB_EMIT_EPS`) | drops by the unforwarded tail | Use when ingest cost dominates and crashes are rare |
| Index-Time (C) | ≈ `r`, minus overhead | 100% | ~100% | Use when completeness is critical |

**Trade-off:** Edge aggregation forwards far fewer records (lower ingest/network
cost) but exposes an in-memory buffer that is lost on collector crash.
Index-time aggregation forwards everything (higher ingest cost) but preserves
exact counts and survives crashes. Both reach the same storage floor (~`r`); the
decision is ingest-cost vs. crash-completeness. The framework maps `dup_ratio`
and the operational failure tolerance to the appropriate pipeline.

Validation performed on this setup: distinct normalized signatures == `N·(1−r)`
at `r ∈ {0, 0.3, 0.6, 0.9}` (so SRR≈`r`), simulated `IPR_C = 1.000`,
`IPR_B ≈ 0.999` normal, `CE = 1/(1−r)`.

## Graphs Generated

1. **Failure Impact Graph** — IPR under normal vs. failure conditions (answers: "Where does loss come from?")
2. **Trade-off Curve** — SRR vs. IPR scatter across all workloads (answers: "What are my options?")
3. **Storage Reduction vs. Duplicate Ratio** — Performance across duplication spectrum
4. **Cumulative Growth (No Clean Slate)** — Long-term storage growth comparison
