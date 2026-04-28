#!/usr/bin/env python3
import json
from pathlib import Path

import numpy as np


def main():
    low = np.linspace(0.00, 0.30, 33)
    med = np.linspace(0.30, 0.70, 40)
    high = np.linspace(0.70, 0.90, 27)
    all_ratios = [round(float(r), 4) for r in np.concatenate([low, med, high])]

    workloads = []
    for i, ratio in enumerate(all_ratios):
        category = "low" if ratio <= 0.30 else "med" if ratio <= 0.70 else "high"
        workloads.append(
            {
                "id": i + 1,
                "dup_ratio": ratio,
                "category": category,
                "total_logs": 1000000,
                "seed": 42 + i,
            }
        )

    output_path = Path("workloads/workloads.json")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, "w") as f:
        json.dump(workloads, f, indent=2)

    print(f"Generated {len(workloads)} workloads → {output_path}")
    print(f"  Low (0-30%):  {sum(1 for w in workloads if w['category'] == 'low')}")
    print(f"  Med (30-70%): {sum(1 for w in workloads if w['category'] == 'med')}")
    print(f"  High (70-90%): {sum(1 for w in workloads if w['category'] == 'high')}")


if __name__ == "__main__":
    main()
