#!/usr/bin/env python3
"""Compute metrics and figures from the experiment result CSVs.

Metric definitions (all measured from data, nothing hardcoded):

    SRR  = 1 - storage / storage_baseline(A)      storage reduction (real bytes)
    SRR* = dup_ratio                              theoretical reduction (reference)
    IPR  = reconstructed / N                      info preserved (sum of count / N)
    CE   = N / M                                  compression efficiency
    FLR  = IPR_normal - IPR_failure               loss caused by collector crash

`reconstructed` is the sum of the per-doc `count` field, i.e. how many original
log lines the aggregated index claims to represent. For baseline A it equals the
doc count (one doc per line), so IPR_A == 1 by construction.
"""
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

BASE_DIR = Path(__file__).parent.parent
RESULTS_DIR = BASE_DIR / "results"
OUTPUT_DIR = BASE_DIR / "output"
OUTPUT_DIR.mkdir(exist_ok=True)

PIPE_NAMES = {"A": "Baseline", "B": "Edge", "C": "Index-Time"}
COLORS = {"A": "gray", "B": "red", "C": "blue"}


def category(ratio):
    return "low" if ratio <= 0.30 else "med" if ratio <= 0.70 else "high"


def calculate_metrics(df):
    baseline = df[df["pipeline"] == "A"].set_index("workload_id")["storage"].to_dict()
    rows = []
    for _, r in df.iterrows():
        N, M, storage = r["N"], r["M"], r["storage"]
        recon = r.get("reconstructed", M)
        base_storage = baseline.get(r["workload_id"], storage)
        rows.append(
            {
                "pipeline": r["pipeline"],
                "workload_id": r["workload_id"],
                "dup_ratio": r["dup_ratio"],
                "category": category(r["dup_ratio"]),
                "N": N,
                "M": M,
                "reconstructed": recon,
                "storage": storage,
                "SRR": 1 - (storage / base_storage) if base_storage > 0 else 0.0,
                "SRR_theoretical": r["dup_ratio"],
                "CE": N / M if M > 0 else 0.0,
                "IPR": min(1.0, recon / N) if N > 0 else 0.0,
            }
        )
    return pd.DataFrame(rows)


def ipr_by_pipeline(df):
    return {p: df[df["pipeline"] == p]["IPR"].mean() for p in ["A", "B", "C"]}


def plot_failure_impact(normal, failure):
    fig, ax = plt.subplots(figsize=(10, 6))
    pipelines = ["A", "B", "C"]
    x = np.arange(len(pipelines))
    width = 0.35
    nrm = ipr_by_pipeline(normal)
    flr = ipr_by_pipeline(failure) if failure is not None else {p: np.nan for p in pipelines}
    ax.bar(x - width / 2, [nrm[p] for p in pipelines], width, label="No Failure", color="steelblue")
    ax.bar(x + width / 2, [flr[p] for p in pipelines], width, label="With Failure", color="coral")
    ax.set_xlabel("Pipeline")
    ax.set_ylabel("IPR (reconstructed / N)")
    ax.set_title("Failure Impact on Information Preservation")
    ax.set_xticks(x)
    ax.set_xticklabels([PIPE_NAMES[p] for p in pipelines])
    ax.legend()
    ax.set_ylim(0.0, 1.02)
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "failure_impact.png", dpi=300)
    plt.close()


def plot_tradeoff(df):
    fig, ax = plt.subplots(figsize=(10, 8))
    for p in ["A", "B", "C"]:
        d = df[df["pipeline"] == p]
        ax.scatter(d["SRR"], d["IPR"], c=COLORS[p], s=20, alpha=0.5, label=PIPE_NAMES[p])
    ax.set_xlabel("Storage Reduction Ratio (SRR)")
    ax.set_ylabel("Information Preservation Ratio (IPR)")
    ax.set_title("Trade-off: Storage Reduction vs Information Preservation")
    ax.set_xlim(-0.05, 1.05)
    ax.set_ylim(0.0, 1.02)
    ax.grid(True, alpha=0.3)
    ax.legend()
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "tradeoff_curve.png", dpi=300)
    plt.close()


def plot_srr_by_dup(df):
    fig, ax = plt.subplots(figsize=(12, 6))
    for p in ["A", "B", "C"]:
        d = df[df["pipeline"] == p].sort_values("dup_ratio")
        ax.scatter(d["dup_ratio"] * 100, d["SRR"] * 100, c=COLORS[p], s=20, alpha=0.6, label=PIPE_NAMES[p])
    # Theoretical maximum: SRR* = dup_ratio.
    xs = np.linspace(0, 90, 100)
    ax.plot(xs, xs, "k--", alpha=0.6, label="Theoretical max (SRR = dup_ratio)")
    ax.set_xlabel("Duplicate Ratio (%)")
    ax.set_ylabel("Storage Reduction (%)")
    ax.set_title("Storage Reduction vs Duplicate Ratio")
    ax.legend()
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "srr_vs_dupratio.png", dpi=300)
    plt.close()


def generate_table(df, failure=None):
    summary = (
        df.groupby(["pipeline", "category"])
        .agg(M=("M", "mean"), storage=("storage", "mean"),
             SRR_Mean=("SRR", "mean"), SRR_Std=("SRR", "std"),
             IPR_Mean=("IPR", "mean"), CE_Mean=("CE", "mean"))
        .round(4)
        .reset_index()
    )
    summary["Avg_Docs"] = summary["M"].round(0).astype(int)
    summary["Avg_Storage_MB"] = (summary["storage"] / (1024 * 1024)).round(2)

    # Empirical FLR per (pipeline, category): IPR_normal - IPR_failure.
    if failure is not None:
        fail_ipr = (
            failure.groupby(["pipeline", "category"])["IPR"].mean().rename("IPR_Failure")
        )
        summary = summary.merge(fail_ipr, on=["pipeline", "category"], how="left")
        summary["FLR_Mean"] = (summary["IPR_Mean"] - summary["IPR_Failure"]).round(4)
    else:
        summary["IPR_Failure"] = np.nan
        summary["FLR_Mean"] = np.nan

    return summary[
        ["pipeline", "category", "Avg_Docs", "Avg_Storage_MB",
         "SRR_Mean", "SRR_Std", "IPR_Mean", "IPR_Failure", "FLR_Mean", "CE_Mean"]
    ]


def plot_cumulative_no_clean_slate(df):
    fig, ax = plt.subplots(figsize=(12, 7))
    for p in ["A", "B", "C"]:
        d = df[df["pipeline"] == p].sort_values("workload_id")
        if d.empty:
            continue
        ax.plot(d["workload_id"], d["total_storage"] / (1024 * 1024),
                marker="o", markersize=2, label=f"Pipeline {p} ({PIPE_NAMES[p]})")
    ax.set_xlabel("Workload Number (Sequential, No Clean Slate)")
    ax.set_ylabel("Cumulative Storage (MB)")
    ax.set_title("Cumulative Storage Growth Without Clean Slate")
    ax.legend()
    ax.grid(True, alpha=0.3)
    ax.axvline(x=33, color="gray", linestyle="--", alpha=0.5)
    ax.axvline(x=73, color="gray", linestyle="--", alpha=0.5)
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "cumulative_no_clean_slate.png", dpi=300)
    plt.close()


def summarize_no_clean_slate(df):
    finals = {p: df[df["pipeline"] == p].sort_values("workload_id").iloc[-1]
              for p in ["A", "B", "C"] if not df[df["pipeline"] == p].empty}
    base = finals["A"]["total_storage"] if "A" in finals else 0
    rows = []
    for p in ["A", "B", "C"]:
        if p not in finals:
            continue
        last = finals[p]
        srr = 1 - (last["total_storage"] / base) if base > 0 else 0
        rows.append(
            {
                "Pipeline": p,
                "Workloads": int(df[df["pipeline"] == p].shape[0]),
                "Final_Docs": int(last["M"]),
                "Final_Storage_MB": round(last["total_storage"] / (1024 * 1024), 2),
                "Cumulative_SRR": round(srr, 4),
            }
        )
    return pd.DataFrame(rows)


def analyze_clean_slate(clean_csv, failure_csv):
    print("Clean-slate analysis...")
    normal = calculate_metrics(pd.read_csv(clean_csv))
    failure = calculate_metrics(pd.read_csv(failure_csv)) if failure_csv.exists() else None
    if failure is None:
        print(f"  (no failure run at {failure_csv}; FLR columns will be blank)")

    plot_failure_impact(normal, failure)
    plot_tradeoff(normal)
    plot_srr_by_dup(normal)
    table = generate_table(normal, failure)
    table.to_csv(OUTPUT_DIR / "comparison_table.csv", index=False)
    table.to_markdown(OUTPUT_DIR / "comparison_table.md", index=False)
    print("\n=== CLEAN SLATE RESULTS ===")
    print(table.to_markdown(index=False))


def analyze_no_clean_slate(csv_path):
    print("No-clean-slate analysis...")
    df = pd.read_csv(csv_path)
    plot_cumulative_no_clean_slate(df)
    summary = summarize_no_clean_slate(df)
    summary.to_csv(OUTPUT_DIR / "cumulative_summary.csv", index=False)
    summary.to_markdown(OUTPUT_DIR / "cumulative_summary.md", index=False)
    print("\n=== NO CLEAN SLATE RESULTS ===")
    print(summary.to_markdown(index=False))


def main():
    print("Analyzing...")
    ran = False
    clean_csv = RESULTS_DIR / "experiments_clean_slate.csv"
    failure_csv = RESULTS_DIR / "experiments_failure.csv"
    ncs_csv = RESULTS_DIR / "experiments_no_clean_slate.csv"

    if clean_csv.exists():
        analyze_clean_slate(clean_csv, failure_csv)
        ran = True
    else:
        print(f"Skipping clean-slate: {clean_csv} not found")

    if ncs_csv.exists():
        analyze_no_clean_slate(ncs_csv)
        ran = True
    else:
        print(f"Skipping no-clean-slate: {ncs_csv} not found")

    print(f"\nSaved to {OUTPUT_DIR}" if ran else "No result CSVs found. Run ./scripts/run_all.sh first.")


if __name__ == "__main__":
    main()
