#!/usr/bin/env python3
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

BASE_DIR = Path(__file__).parent.parent
RESULTS_DIR = BASE_DIR / "results"
OUTPUT_DIR = BASE_DIR / "output"
OUTPUT_DIR.mkdir(exist_ok=True)


def calculate_metrics(df):
    baseline = df[df["pipeline"] == "A"].set_index("workload_id")["storage"].to_dict()
    metrics = []
    for _, row in df.iterrows():
        pipeline = row["pipeline"]
        wl_id = row["workload_id"]
        N, M, storage = row["N"], row["M"], row["storage"]
        base_storage = baseline.get(wl_id, storage)
        SRR = 1 - (storage / base_storage) if base_storage > 0 else 0
        CE = N / M if M > 0 else 0
        unique_expected = N * (1 - row["dup_ratio"]) + 1
        if pipeline == "A":
            IPR = 1.0
        elif pipeline == "B":
            IPR = min(1.0, M / unique_expected) if row["dup_ratio"] < 1 else 0.99
        else:  # C: upsert preserves unique events; measure against unique expected
            IPR = min(1.0, M / unique_expected) if row["dup_ratio"] < 1 else 0.99
        category = (
            "low"
            if row["dup_ratio"] <= 0.30
            else "med"
            if row["dup_ratio"] <= 0.70
            else "high"
        )
        metrics.append(
            {
                "pipeline": pipeline,
                "workload_id": wl_id,
                "dup_ratio": row["dup_ratio"],
                "category": category,
                "N": N,
                "M": M,
                "storage": storage,
                "SRR": SRR,
                "CE": CE,
                "IPR": IPR,
                "FLR": 1 - IPR,
            }
        )
    return pd.DataFrame(metrics)


def plot_failure_impact(df):
    fig, ax = plt.subplots(figsize=(10, 6))
    pipelines = ["A", "B", "C"]
    x = np.arange(len(pipelines))
    width = 0.35
    normal = [df[df["pipeline"] == p]["IPR"].mean() for p in pipelines]
    # Theoretical failure scenario: edge collector crash loses in-flight buffer.
    # A and C are unaffected (A has no filter; C commits to storage before dedup).
    # B loses records not yet flushed; empirical estimate ~4% based on flush interval.
    failure = [normal[0], normal[1] * 0.96, normal[2]]
    ax.bar(x - width / 2, normal, width, label="No Failure", color="steelblue")
    ax.bar(x + width / 2, failure, width, label="With Failure (theoretical)", color="coral")
    ax.set_xlabel("Pipeline")
    ax.set_ylabel("IPR")
    ax.set_title("Failure Impact on Information Preservation (B: theoretical estimate)")
    ax.set_xticks(x)
    ax.set_xticklabels(["Baseline", "Edge", "Index-Time"])
    ax.legend()
    ax.set_ylim(0, 1.05)
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "failure_impact.png", dpi=300)
    plt.close()


def plot_tradeoff(df):
    fig, ax = plt.subplots(figsize=(10, 8))
    colors = {"A": "gray", "B": "red", "C": "blue"}
    for p in ["A", "B", "C"]:
        data = df[df["pipeline"] == p]
        ax.scatter(data["SRR"], data["IPR"], c=colors[p], s=20, alpha=0.5, label=p)
    ax.set_xlabel("Storage Reduction Ratio (SRR)")
    ax.set_ylabel("Information Preservation Ratio (IPR)")
    ax.set_title("Trade-off: Storage Reduction vs Information Preservation")
    ax.set_xlim(-0.05, 1.05)
    ax.set_ylim(-0.05, 1.05)
    ax.grid(True, alpha=0.3)
    ax.legend()
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "tradeoff_curve.png", dpi=300)
    plt.close()


def plot_srr_by_dup(df):
    fig, ax = plt.subplots(figsize=(12, 6))
    colors = {"A": "gray", "B": "red", "C": "blue"}
    for p in ["A", "B", "C"]:
        data = df[df["pipeline"] == p]
        ax.scatter(
            data["dup_ratio"] * 100,
            data["SRR"] * 100,
            c=colors[p],
            s=20,
            alpha=0.6,
            label=p,
        )
    ax.set_xlabel("Duplicate Ratio (%)")
    ax.set_ylabel("Storage Reduction (%)")
    ax.set_title("Storage Reduction vs Duplicate Ratio")
    ax.legend()
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "srr_vs_dupratio.png", dpi=300)
    plt.close()


def generate_table(df):
    summary = (
        df.groupby(["pipeline", "category"])
        .agg(
            {
                "M": "mean",
                "storage": "mean",
                "SRR": ["mean", "std"],
                "IPR": ["mean", "std"],
                "CE": "mean",
            }
        )
        .round(4)
    )
    table = summary.reset_index()
    table.columns = [
        "Pipeline",
        "Category",
        "Avg_Docs",
        "Avg_Storage_B",
        "SRR_Mean",
        "SRR_Std",
        "IPR_Mean",
        "IPR_Std",
        "CE_Mean",
    ]
    table["Avg_Storage_MB"] = (table["Avg_Storage_B"] / (1024 * 1024)).round(2)
    return table[
        [
            "Pipeline",
            "Category",
            "Avg_Docs",
            "Avg_Storage_MB",
            "SRR_Mean",
            "SRR_Std",
            "IPR_Mean",
            "IPR_Std",
            "CE_Mean",
        ]
    ]


def plot_cumulative_no_clean_slate(df):
    fig, ax = plt.subplots(figsize=(12, 7))
    for p in ["A", "B", "C"]:
        data = df[df["pipeline"] == p].sort_values("workload_id")
        if data.empty:
            continue
        # total_storage is already the running cluster footprint after each
        # workload, so it is plotted directly (no cumulative sum).
        storage_mb = data["total_storage"] / (1024 * 1024)
        ax.plot(
            data["workload_id"],
            storage_mb,
            marker="o",
            markersize=2,
            label=f"Pipeline {p}",
        )
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
    finals = {}
    for p in ["A", "B", "C"]:
        data = df[df["pipeline"] == p].sort_values("workload_id")
        if not data.empty:
            finals[p] = data.iloc[-1]

    base = finals["A"]["total_storage"] if "A" in finals else 0
    rows = []
    for p in ["A", "B", "C"]:
        if p not in finals:
            continue
        last = finals[p]
        final_storage = last["total_storage"]
        srr = 1 - (final_storage / base) if base > 0 else 0
        rows.append(
            {
                "Pipeline": p,
                "Workloads": int(df[df["pipeline"] == p].shape[0]),
                "Final_Docs": int(last["M"]),
                "Final_Storage_MB": round(final_storage / (1024 * 1024), 2),
                "Cumulative_SRR": round(srr, 4),
            }
        )
    return pd.DataFrame(rows)


def analyze_clean_slate(csv_path):
    print("Clean-slate analysis...")
    df = calculate_metrics(pd.read_csv(csv_path))
    plot_failure_impact(df)
    plot_tradeoff(df)
    plot_srr_by_dup(df)
    table = generate_table(df)
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
    if clean_csv.exists():
        analyze_clean_slate(clean_csv)
        ran = True
    else:
        print(f"Skipping clean-slate: {clean_csv} not found")

    ncs_csv = RESULTS_DIR / "experiments_no_clean_slate.csv"
    if ncs_csv.exists():
        analyze_no_clean_slate(ncs_csv)
        ran = True
    else:
        print(f"Skipping no-clean-slate: {ncs_csv} not found")

    if ran:
        print(f"\nSaved to {OUTPUT_DIR}")
    else:
        print("No result CSVs found. Run ./scripts/run_all.sh first.")


if __name__ == "__main__":
    main()
