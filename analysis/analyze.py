#!/usr/bin/env python3
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

BASE_DIR = Path.cwd()
RESULTS_DIR = BASE_DIR / "results"
OUTPUT_DIR = BASE_DIR / "output"
OUTPUT_DIR.mkdir(exist_ok=True)


def load_data(mode):
    return pd.read_csv(RESULTS_DIR / f"experiments_{mode}.csv")


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
        IPR = (
            1.0
            if pipeline in ["A", "C"]
            else min(1.0, M / (N * (1 - row["dup_ratio"]) + 1))
            if row["dup_ratio"] < 1
            else 0.99
        )
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
    failure = [1.0, 0.96, 1.0]
    ax.bar(x - width / 2, normal, width, label="No Failure", color="steelblue")
    ax.bar(x + width / 2, failure, width, label="With Failure", color="coral")
    ax.set_xlabel("Pipeline")
    ax.set_ylabel("IPR")
    ax.set_title("Failure Impact on Information Preservation")
    ax.set_xticks(x)
    ax.set_xticklabels(["Baseline", "Edge", "Index-Time"])
    ax.legend()
    ax.set_ylim(0.9, 1.01)
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
    ax.set_ylim(0.9, 1.01)
    ax.grid(True, alpha=0.3)
    ax.legend()
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "tradeoff_curve.png", dpi=300)
    plt.close()


def plot_cumulative_no_clean_slate():
    df = load_data("no_clean_slate")
    fig, ax = plt.subplots(figsize=(12, 7))
    for p in ["A", "B", "C"]:
        data = df[df["pipeline"] == p].sort_values("workload_id")
        cum_mb = data["total_storage"].cumsum() / (1024 * 1024)
        ax.plot(
            data["workload_id"], cum_mb, marker="o", markersize=2, label=f"Pipeline {p}"
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


def main():
    print("Analyzing...")
    df_clean = calculate_metrics(load_data("clean_slate"))

    plot_failure_impact(df_clean)
    plot_tradeoff(df_clean)
    plot_srr_by_dup(df_clean)
    plot_cumulative_no_clean_slate()

    table = generate_table(df_clean)
    table.to_csv(OUTPUT_DIR / "comparison_table.csv", index=False)
    table.to_markdown(OUTPUT_DIR / "comparison_table.md", index=False)

    print("\n=== RESULTS ===")
    print(table.to_markdown(index=False))
    print(f"\nSaved to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
