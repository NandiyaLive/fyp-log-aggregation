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

Storage validity
----------------
A run's `storage` figure is only meaningful once OpenSearch has merged the index
down to a single segment. Older runs used a synchronous force-merge with a
client-side timeout; when the merge outran that timeout the pre-merge size was
recorded instead, inflating storage by 2-4x. Those rows are detected here and
excluded from every storage-derived metric (SRR, Avg_Storage_MB) -- they are
measurement artifacts, not results.

Two detection signals, either one invalidates the storage figure:
  * `settled == false`   -- the run itself reported an unfinished merge
                            (written by run_experiment.sh; absent in older CSVs)
  * bytes-per-doc > 1.5x the pipeline's median  -- retrospective detection for
                            CSVs recorded before the `settled` column existed

Detection is on bytes-per-doc (storage / M), not on raw storage. Raw storage is
not comparable within a pipeline: at high duplicate ratios B and C legitimately
produce a much smaller index, so a bloated high-dup run can still sit below the
pipeline's overall median and escape a raw-size threshold. Bytes-per-doc is flat
across dup ratios for a merged index (A ~227 B/doc, B and C ~396 B/doc, spread
within +/-20%) and jumps to 3-5x when segments were never merged, so the two
populations separate with no overlap.

SRR is a paired metric (pipeline vs baseline A on the same workload), so it is
computed only when BOTH the row and its A baseline have valid storage.

Doc counts (N, M, reconstructed) are unaffected by the merge state, so IPR, CE
and all failure metrics use every row.
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

# A bytes-per-doc figure more than this multiple of its pipeline's median is
# treated as an unmerged-index artifact. Merged runs sit within ~20% of the
# median; the artifacts sit at 3-5x, so the threshold falls in an empty gap.
STORAGE_OUTLIER_FACTOR = 1.5


def category(ratio):
    return "low" if ratio <= 0.30 else "med" if ratio <= 0.70 else "high"


def flag_storage_validity(df):
    """Mark rows whose `storage` was measured on a fully merged index."""
    df = df.copy()
    valid = pd.Series(True, index=df.index)

    if "settled" in df.columns:
        settled = df["settled"].astype(str).str.strip().str.lower()
        valid &= settled != "false"

    df["bytes_per_doc"] = np.where(df["M"] > 0, df["storage"] / df["M"], np.nan)
    medians = df.groupby("pipeline")["bytes_per_doc"].transform("median")
    df["bloat"] = df["bytes_per_doc"] / medians
    valid &= df["bloat"] <= STORAGE_OUTLIER_FACTOR

    df["storage_valid"] = valid
    return df


def report_exclusions(df, label):
    excluded = df[~df["storage_valid"]]
    total, n = len(df), len(excluded)
    if n == 0:
        print(f"  [{label}] storage: all {total} runs merged cleanly")
        return
    print(f"  [{label}] storage: excluded {n}/{total} unmerged runs "
          f"(bytes/doc > {STORAGE_OUTLIER_FACTOR}x pipeline median, or settled=false)")
    for p in ["A", "B", "C"]:
        ex = excluded[excluded["pipeline"] == p]
        if ex.empty:
            continue
        ids = ", ".join(f"wl{int(r.workload_id)}({r.bloat:.1f}x)" for r in ex.itertuples())
        print(f"      {p}: {len(ex)} -> {ids}")


def calculate_metrics(df):
    df = flag_storage_validity(df)
    valid_base = df[(df["pipeline"] == "A") & df["storage_valid"]]
    baseline = valid_base.set_index("workload_id")["storage"].to_dict()
    rows = []
    for _, r in df.iterrows():
        N, M, storage = r["N"], r["M"], r["storage"]
        recon = r.get("reconstructed", M)
        # SRR needs a trustworthy numerator AND denominator; without both it is
        # left as NaN so it drops out of means rather than skewing them.
        base_storage = baseline.get(r["workload_id"])
        if r["storage_valid"] and base_storage and base_storage > 0:
            srr = 1 - (storage / base_storage)
        else:
            srr = np.nan
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
                "storage_valid": r["storage_valid"],
                "bytes_per_doc": r["bytes_per_doc"],
                "bloat": r["bloat"],
                "SRR": srr,
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
    b1 = ax.bar(x - width / 2, [nrm[p] for p in pipelines], width, label="No Failure", color="steelblue")
    b2 = ax.bar(x + width / 2, [flr[p] for p in pipelines], width, label="With Failure", color="coral")
    for b in (b1, b2):
        for rect in b:
            h = rect.get_height()
            if np.isnan(h):
                continue
            ax.annotate(f"{h:.4f}", xy=(rect.get_x() + rect.get_width() / 2, h),
                        xytext=(0, 2), textcoords="offset points",
                        ha="center", va="bottom", fontsize=9)
    ax.set_xlabel("Pipeline")
    ax.set_ylabel("IPR (reconstructed / N)")
    ax.set_title("Failure Impact on Information Preservation")
    ax.set_xticks(x)
    ax.set_xticklabels([PIPE_NAMES[p] for p in pipelines])
    ax.legend()
    ax.set_ylim(0.0, 1.06)
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "failure_impact.png", dpi=300)
    plt.close()


def plot_tradeoff(normal, failure):
    if failure is None:
        return
    merged = normal.merge(
        failure[["pipeline", "workload_id", "IPR"]].rename(columns={"IPR": "IPR_failure"}),
        on=["pipeline", "workload_id"],
        how="left",
    )
    merged["FLR"] = 1 - merged["IPR_failure"]
    merged = merged.dropna(subset=["SRR"])   # unmerged-index runs have no valid SRR
    fig, ax = plt.subplots(figsize=(10, 8))
    for p in ["A", "B", "C"]:
        d = merged[merged["pipeline"] == p]
        ax.scatter(d["SRR"], d["FLR"], c=COLORS[p], s=20, alpha=0.5, label=PIPE_NAMES[p])
    ax.set_xlabel("Storage Reduction Ratio (SRR)")
    ax.set_ylabel("Failure Loss Rate (FLR = 1 − IPR_failure)")
    ax.set_title("Trade-off: Storage Reduction vs Failure Loss Rate")
    ax.grid(True, alpha=0.3)
    ax.legend()
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "tradeoff_curve.png", dpi=300)
    plt.close()


def plot_srr_by_dup(df):
    df = df.dropna(subset=["SRR"])           # unmerged-index runs have no valid SRR
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


def plot_storage_line(df):
    """Storage per workload. Excluded (unmerged-index) runs are drawn hollow so
    the artifact is visible in the figure rather than silently dropped."""
    fig, ax = plt.subplots(figsize=(12, 6))
    for p in ["A", "B", "C"]:
        d = df[df["pipeline"] == p].sort_values("workload_id")
        ok = d[d["storage_valid"]]
        bad = d[~d["storage_valid"]]
        ax.plot(ok["workload_id"], ok["storage"] / (1024 * 1024),
                marker="o", markersize=3, linewidth=1, color=COLORS[p],
                label=f"{PIPE_NAMES[p]} (included)")
        ax.scatter(bad["workload_id"], bad["storage"] / (1024 * 1024),
                   facecolors="none", edgecolors=COLORS[p], s=45, linewidths=1.2,
                   label=f"{PIPE_NAMES[p]} (excluded: unmerged index)")
    ax.set_xlabel("Workload Number (ordered by duplicate ratio)")
    ax.set_ylabel("Index Storage (MB)")
    ax.set_title("Storage per Workload, with Unmerged-Index Runs Marked")
    ax.legend(fontsize=8, ncol=2)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "storage_line_all_pipelines.png", dpi=300)
    plt.close()


def plot_ipr_bar_grouped(normal, failure):
    """Grouped bar chart: IPR per (pipeline, category), normal vs failure."""
    if failure is None:
        return
    cats = ["low", "med", "high"]
    pipelines = ["A", "B", "C"]
    nrm = (normal.groupby(["pipeline", "category"])["IPR"].mean()
           .reindex([(p, c) for p in pipelines for c in cats], fill_value=0.0))
    flr = (failure.groupby(["pipeline", "category"])["IPR"].mean()
           .reindex([(p, c) for p in pipelines for c in cats], fill_value=0.0))

    labels = [f"{PIPE_NAMES[p]}\n{c}" for p in pipelines for c in cats]
    x = np.arange(len(labels))
    width = 0.38

    fig, ax = plt.subplots(figsize=(14, 6))
    b1 = ax.bar(x - width / 2, nrm.values, width, label="No Failure", color="steelblue")
    b2 = ax.bar(x + width / 2, flr.values, width, label="With Failure", color="coral")

    for b in (b1, b2):
        for rect in b:
            h = rect.get_height()
            ax.annotate(f"{h:.4f}", xy=(rect.get_x() + rect.get_width() / 2, h),
                        xytext=(0, 2), textcoords="offset points",
                        ha="center", va="bottom", fontsize=8)

    for boundary in (2.5, 5.5):
        ax.axvline(boundary, color="gray", linestyle=":", alpha=0.5)

    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylabel("IPR (reconstructed / N)")
    ax.set_title("IPR by Pipeline and Workload Category: Normal vs Failure")
    ax.set_ylim(0.0, 1.08)
    ax.legend()
    ax.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "ipr_bar_grouped.png", dpi=300)
    plt.close()


def plot_ipr_vs_dupratio(normal, failure):
    fig, axes = plt.subplots(1, 2, figsize=(16, 6), sharey=True)
    for ax, df, title in [(axes[0], normal, "Normal"),
                          (axes[1], failure, "With Failure Injection")]:
        if df is None:
            ax.set_visible(False)
            continue
        for p in ["A", "B", "C"]:
            d = df[df["pipeline"] == p].sort_values("dup_ratio")
            ax.scatter(d["dup_ratio"] * 100, d["IPR"], c=COLORS[p], s=20,
                       alpha=0.6, label=PIPE_NAMES[p])
        ax.set_xlabel("Duplicate Ratio (%)")
        ax.set_title(f"IPR vs Workload Duplicate Ratio ({title})")
        ax.grid(True, alpha=0.3)
        ax.legend()
        ax.set_ylim(0.0, 1.05)
    axes[0].set_ylabel("IPR (reconstructed / N)")
    plt.tight_layout()
    plt.savefig(OUTPUT_DIR / "ipr_vs_dupratio.png", dpi=300)
    plt.close()


def generate_table(df, failure=None):
    # Doc-count metrics use every run; storage metrics only the merged ones.
    summary = (
        df.groupby(["pipeline", "category"])
        .agg(M=("M", "mean"), IPR_Mean=("IPR", "mean"), CE_Mean=("CE", "mean"),
             N_Runs=("M", "size"))
        .round(4)
        .reset_index()
    )
    storage_stats = (
        df[df["storage_valid"]]
        .groupby(["pipeline", "category"])
        .agg(storage=("storage", "mean"),
             SRR_Mean=("SRR", "mean"), SRR_Std=("SRR", "std"),
             N_Storage=("storage", "size"))
        .round(4)
        .reset_index()
    )
    summary = summary.merge(storage_stats, on=["pipeline", "category"], how="left")
    summary["N_Storage"] = summary["N_Storage"].fillna(0).astype(int)
    summary["Avg_Docs"] = summary["M"].round(0).astype(int)
    summary["Avg_Storage_MB"] = (summary["storage"] / (1024 * 1024)).round(2)

    # Empirical FLR per (pipeline, category): IPR_normal - IPR_failure.
    if failure is not None:
        fail_ipr = (
            failure.groupby(["pipeline", "category"])["IPR"].mean().rename("IPR_Failure")
        )
        summary = summary.merge(fail_ipr, on=["pipeline", "category"], how="left")
        summary["FLR_Mean"] = (1 - summary["IPR_Failure"]).round(4)
    else:
        summary["IPR_Failure"] = np.nan
        summary["FLR_Mean"] = np.nan

    return summary[
        ["pipeline", "category", "N_Runs", "N_Storage", "Avg_Docs", "Avg_Storage_MB",
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

    report_exclusions(normal, "clean_slate")
    if failure is not None:
        report_exclusions(failure, "failure")

    plot_failure_impact(normal, failure)
    plot_tradeoff(normal, failure)
    plot_storage_line(normal)
    plot_srr_by_dup(normal)
    plot_ipr_vs_dupratio(normal, failure)
    plot_ipr_bar_grouped(normal, failure)
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
