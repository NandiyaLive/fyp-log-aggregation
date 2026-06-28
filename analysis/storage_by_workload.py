#!/usr/bin/env python3
"""Storage consumed per workload per pipeline, categorized by duplication level.

Outputs:
  output/storage_bar_by_pipeline.png  — bar chart (3 rows: pipeline A / B / C, bars colored by dup category)
  output/storage_line_by_pipeline.png — line chart (same layout)
"""
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np
import pandas as pd
from matplotlib.patches import Patch

BASE_DIR = Path(__file__).parent.parent
CSV = BASE_DIR / "results" / "experiments_clean_slate.csv"
OUT = BASE_DIR / "output"
OUT.mkdir(exist_ok=True)

PIPE_NAMES = {"A": "Baseline (A)", "B": "Edge (B)", "C": "Index-Time (C)"}
PIPE_COLORS = {"A": "#555555", "B": "#d62728", "C": "#1f77b4"}
CAT_COLORS = {"low": "#2ca02c", "mid": "#ff7f0e", "high": "#9467bd"}
CAT_LABELS = {"low": "Low Dup (≤ 30%)", "mid": "Mid Dup (30–70%)", "high": "High Dup (> 70%)"}
CATEGORIES = ["low", "mid", "high"]


def dup_category(ratio):
    if ratio <= 0.30:
        return "low"
    elif ratio <= 0.70:
        return "mid"
    return "high"


def load():
    df = pd.read_csv(CSV)
    df["category"] = df["dup_ratio"].apply(dup_category)
    df["storage_mb"] = df["storage"] / (1024 * 1024)
    return df


def plot_bars(df):
    for pipe in ["A", "B", "C"]:
        sub = df[df["pipeline"] == pipe].sort_values("workload_id")
        workloads = sub["workload_id"].tolist()
        storage = sub["storage_mb"].tolist()
        cats = sub["category"].tolist()

        fig, ax = plt.subplots(figsize=(16, 5))
        x = np.arange(len(workloads))
        ax.bar(x, storage, color=[CAT_COLORS[c] for c in cats], alpha=0.85, width=0.7)

        ax.set_title(f"Storage per Workload — Pipeline {PIPE_NAMES[pipe]}", fontsize=13, fontweight="bold")
        ax.set_ylabel("Storage (MB)")
        ax.set_xlabel("Workload ID")
        step = max(1, len(workloads) // 20)
        ax.set_xticks(x[::step])
        ax.set_xticklabels([str(workloads[j]) for j in range(0, len(workloads), step)],
                           rotation=45, ha="right", fontsize=8)
        ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{v:.0f}"))
        ax.grid(axis="y", alpha=0.3)
        ax.legend(handles=[Patch(facecolor=CAT_COLORS[c], label=CAT_LABELS[c]) for c in CATEGORIES],
                  loc="upper right", fontsize=9)

        plt.tight_layout()
        out_path = OUT / f"storage_bar_pipeline_{pipe}.png"
        plt.savefig(out_path, dpi=150)
        plt.close()
        print(f"Saved: {out_path}")


def plot_lines(df):
    for pipe in ["A", "B", "C"]:
        sub = df[df["pipeline"] == pipe].sort_values("workload_id")
        workloads = sub["workload_id"].tolist()

        fig, ax = plt.subplots(figsize=(16, 5))

        ax.plot(workloads, sub["storage_mb"].tolist(),
                color=PIPE_COLORS[pipe], linewidth=0.8, alpha=0.4)
        for cat in CATEGORIES:
            mask = sub["category"] == cat
            ax.scatter(sub.loc[mask, "workload_id"], sub.loc[mask, "storage_mb"],
                       color=CAT_COLORS[cat], s=20, zorder=3, label=CAT_LABELS[cat])

        # Shade background by category region
        prev_x, prev_cat = None, None
        for wl, cat in zip(workloads, sub["category"].tolist()):
            if prev_cat is not None and cat != prev_cat:
                ax.axvspan(prev_x - 0.5, wl - 0.5, alpha=0.07, color=CAT_COLORS[prev_cat])
            prev_x, prev_cat = wl, cat
        if prev_cat is not None:
            ax.axvspan(prev_x - 0.5, workloads[-1] + 0.5, alpha=0.07, color=CAT_COLORS[prev_cat])

        ax.set_title(f"Storage per Workload — Pipeline {PIPE_NAMES[pipe]}", fontsize=13, fontweight="bold")
        ax.set_ylabel("Storage (MB)")
        ax.set_xlabel("Workload ID")
        ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{v:.0f}"))
        ax.grid(alpha=0.3)
        ax.legend(loc="upper right", fontsize=9)

        plt.tight_layout()
        out_path = OUT / f"storage_line_pipeline_{pipe}.png"
        plt.savefig(out_path, dpi=150)
        plt.close()
        print(f"Saved: {out_path}")


def plot_lines_overlaid_normalized(df):
    fig, ax = plt.subplots(figsize=(18, 6))

    for pipe in ["A", "B", "C"]:
        sub = df[df["pipeline"] == pipe].sort_values("workload_id").copy()
        rolling_med = sub["storage_mb"].rolling(window=5, center=True, min_periods=1).median()
        mad = (sub["storage_mb"] - rolling_med).abs().rolling(window=5, center=True, min_periods=1).median()
        threshold = rolling_med + 3 * (mad + 1)
        is_outlier = sub["storage_mb"] > threshold
        clean = sub["storage_mb"].copy()
        clean[is_outlier] = rolling_med[is_outlier]
        smoothed = clean.rolling(window=3, center=True, min_periods=1).mean()

        ax.plot(sub["workload_id"], smoothed,
                color=PIPE_COLORS[pipe], linewidth=1.5, alpha=0.9,
                marker="o", markersize=2, label=PIPE_NAMES[pipe])
        if is_outlier.any():
            ax.scatter(sub.loc[is_outlier, "workload_id"],
                       sub.loc[is_outlier, "storage_mb"],
                       color=PIPE_COLORS[pipe], s=15, marker="x", alpha=0.4, zorder=2)

    # Category background shading
    ref = df[df["pipeline"] == "A"].sort_values("workload_id")
    workloads = ref["workload_id"].tolist()
    cats = ref["category"].tolist()
    prev_x, prev_cat = None, None
    for wl, cat in zip(workloads, cats):
        if prev_cat is not None and cat != prev_cat:
            ax.axvspan(prev_x - 0.5, wl - 0.5, alpha=0.07, color=CAT_COLORS[prev_cat])
        prev_x, prev_cat = wl, cat
    if prev_cat is not None:
        ax.axvspan(prev_x - 0.5, workloads[-1] + 0.5, alpha=0.07, color=CAT_COLORS[prev_cat])

    from matplotlib.patches import Patch as _Patch
    cat_handles = [_Patch(facecolor=CAT_COLORS[c], alpha=0.4, label=CAT_LABELS[c]) for c in CATEGORIES]
    pipe_handles = [plt.Line2D([0], [0], color=PIPE_COLORS[p], linewidth=1.5, label=PIPE_NAMES[p]) for p in ["A", "B", "C"]]
    ax.legend(handles=pipe_handles + cat_handles, loc="upper right", fontsize=9)

    ax.set_title("Storage per Workload — All Pipelines (Normalized: outliers removed via rolling median)",
                 fontsize=13, fontweight="bold")
    ax.set_ylabel("Storage (MB)")
    ax.set_xlabel("Workload ID")
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{v:.0f}"))
    ax.grid(alpha=0.3)

    plt.tight_layout()
    out_path = OUT / "storage_line_all_pipelines_normalized.png"
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Saved: {out_path}")


def plot_lines_overlaid(df):
    fig, ax = plt.subplots(figsize=(18, 6))

    for pipe in ["A", "B", "C"]:
        sub = df[df["pipeline"] == pipe].sort_values("workload_id")
        ax.plot(sub["workload_id"], sub["storage_mb"],
                color=PIPE_COLORS[pipe], linewidth=1.2, alpha=0.85,
                marker="o", markersize=2, label=PIPE_NAMES[pipe])

    # Shade dup category regions (derive from pipeline A as reference)
    ref = df[df["pipeline"] == "A"].sort_values("workload_id")
    workloads = ref["workload_id"].tolist()
    cats = ref["category"].tolist()
    prev_x, prev_cat = None, None
    for wl, cat in zip(workloads, cats):
        if prev_cat is not None and cat != prev_cat:
            ax.axvspan(prev_x - 0.5, wl - 0.5, alpha=0.07, color=CAT_COLORS[prev_cat])
        prev_x, prev_cat = wl, cat
    if prev_cat is not None:
        ax.axvspan(prev_x - 0.5, workloads[-1] + 0.5, alpha=0.07, color=CAT_COLORS[prev_cat])

    # Add category region labels at top
    from matplotlib.patches import Patch as _Patch
    cat_handles = [_Patch(facecolor=CAT_COLORS[c], alpha=0.4, label=CAT_LABELS[c]) for c in CATEGORIES]
    pipe_handles = [plt.Line2D([0], [0], color=PIPE_COLORS[p], linewidth=1.5, label=PIPE_NAMES[p]) for p in ["A", "B", "C"]]
    ax.legend(handles=pipe_handles + cat_handles, loc="upper right", fontsize=9)

    ax.set_title("Storage per Workload — All Pipelines Overlaid", fontsize=13, fontweight="bold")
    ax.set_ylabel("Storage (MB)")
    ax.set_xlabel("Workload ID")
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{v:.0f}"))
    ax.grid(alpha=0.3)

    plt.tight_layout()
    out_path = OUT / "storage_line_all_pipelines.png"
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Saved: {out_path}")


def main():
    if not CSV.exists():
        print(f"Not found: {CSV}")
        return
    df = load()
    plot_bars(df)
    plot_lines(df)
    plot_lines_overlaid(df)
    plot_lines_overlaid_normalized(df)



if __name__ == "__main__":
    main()
