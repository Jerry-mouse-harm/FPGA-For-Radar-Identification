#!/usr/bin/env python3
"""Inspect and verify the generated radar dataset (v3).

Checks:
  - Class x SNR stratification balance
  - Spectrogram validity in [0, 1]
  - Binary spike stream validity in {0, 1}
  - Spike density across SNRs (verifying absence of noise flooding)
  - Occupancy and signal power statistics
  - High-resolution publication-quality visualization with physical units (MHz, us).
"""

import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def summarize(npz_path):
    npz = np.load(npz_path, allow_pickle=False)
    labels = npz["labels"]
    snr = npz["snr"]
    specs = npz["spectrograms"]
    spikes = npz["spikes"]
    signals = npz["signals"]
    occ = npz["occupancy"] if "occupancy" in npz else None

    print(f"== {npz_path.name} ==")
    print(f"  Samples: {len(labels)}")
    print(f"  Signals shape:     {signals.shape} ({signals.dtype})")
    print(f"  Spectrogram shape: {specs.shape} ({specs.dtype})")
    print(f"  Spikes shape:      {spikes.shape} ({spikes.dtype})")

    snr_vals = np.unique(snr)
    n_classes = len(np.unique(labels))

    print("  Stratification Matrix (Rows: SNR dB | Cols: Class 0..4):")
    print("       " + " ".join(f"{c:>6d}" for c in range(n_classes)))
    for s in snr_vals:
        row = " ".join(f"{int(((labels == c) & (snr == s)).sum()):>6d}"
                       for c in range(n_classes))
        print(f"  {s:>4.0f}  {row}")

    # Integrity assertions
    assert np.isfinite(signals).all(), "Signals contain non-finite values!"
    assert np.isfinite(specs).all(), "Spectrograms contain non-finite values!"
    assert specs.min() >= -1e-6 and specs.max() <= 1.0 + 1e-6, "Spectrogram out of [0, 1]!"
    assert spikes.dtype == np.uint8, f"Spikes dtype {spikes.dtype} != uint8!"
    assert set(np.unique(spikes)).issubset({0, 1}), "Spikes are not strictly binary {0, 1}!"

    # Spike density metrics
    overall_density = spikes.mean() * 100.0
    print(f"  Overall spike density: {overall_density:.2f}%")
    print("  Spike density by SNR:")
    for s in snr_vals:
        mask = (snr == s)
        print(f"    SNR {s:>4.0f} dB: {spikes[mask].mean() * 100:.2f}%")

    print("  Spike density by Class:")
    class_names = ["CW", "Pulse", "LFM", "BPSK", "FSK"]
    for c in range(n_classes):
        mask = (labels == c)
        cname = class_names[c] if c < len(class_names) else f"C{c}"
        print(f"    Class {cname:<6s}: {spikes[mask].mean() * 100:.2f}%")

    if occ is not None:
        cw_occ = occ[labels == 0].mean()
        pulsed_occ = occ[labels > 0].mean()
        print(f"  Mean occupancy: CW={cw_occ:.3f}, Pulsed={pulsed_occ:.3f} (std={occ[labels > 0].std():.3f})")

    print("  Integrity: PASS\n")
    return labels, snr, specs, spikes, signals


def plot_examples(dataset_dir, figure_path):
    d = Path(dataset_dir)
    meta = json.load(open(d / "meta.json"))
    class_names = meta["class_names"]
    snr_vals = np.asarray(meta["snr_db"])

    tr = np.load(d / "train.npz", allow_pickle=False)
    specs = tr["spectrograms"]
    spikes = tr["spikes"]
    labels = tr["labels"]
    snrs = tr["snr"]

    nc = len(class_names)
    ns = len(snr_vals)

    # Physical coordinates for plots
    # Time: 0 to 5.12 us, 29 bins
    # Freq: 1.5625 MHz to 62.5 MHz, 40 bins
    t_extent = [0.0, 5.12, 1.5625, 62.5]

    fig, axes = plt.subplots(nc, ns + 2, figsize=(3.2 * (ns + 2), 2.2 * nc))

    for ci, name in enumerate(class_names):
        # Plot spectrograms across SNRs
        for si, s in enumerate(snr_vals):
            idx = np.where((labels == ci) & (snrs == s))[0][0]
            ax = axes[ci, si]
            # Spectrogram is [T=29, F=40], transpose for [F, T] display
            img = specs[idx].T
            im = ax.imshow(img, aspect="auto", origin="lower", extent=t_extent,
                           cmap="viridis", vmin=0, vmax=1)
            if ci == 0:
                ax.set_title(f"Spectrogram @ {s:.0f} dB", fontsize=10, fontweight="bold")
            if si == 0:
                ax.set_ylabel(f"{name}\nFreq (MHz)", fontsize=9, fontweight="bold")
            if ci == nc - 1:
                ax.set_xlabel("Time (μs)", fontsize=9)

        # Plot Spike Raster at SNR = 0 dB
        idx_0db = np.where((labels == ci) & (snrs == 0))[0][0]
        ax_spk0 = axes[ci, ns]
        # Spikes: [T=29, F=40], transpose for [F, T]
        spk_img0 = spikes[idx_0db].T
        ax_spk0.imshow(spk_img0, aspect="auto", origin="lower", extent=t_extent,
                       cmap="binary", vmin=0, vmax=1, interpolation="nearest")
        if ci == 0:
            ax_spk0.set_title("Spikes @ 0 dB", fontsize=10, fontweight="bold")
        if ci == nc - 1:
            ax_spk0.set_xlabel("Time (μs)", fontsize=9)

        # Plot Spike Raster at SNR = 20 dB
        idx_20db = np.where((labels == ci) & (snrs == 20))[0][0]
        ax_spk20 = axes[ci, ns + 1]
        spk_img20 = spikes[idx_20db].T
        ax_spk20.imshow(spk_img20, aspect="auto", origin="lower", extent=t_extent,
                        cmap="binary", vmin=0, vmax=1, interpolation="nearest")
        if ci == 0:
            ax_spk20.set_title("Spikes @ 20 dB", fontsize=10, fontweight="bold")
        if ci == nc - 1:
            ax_spk20.set_xlabel("Time (μs)", fontsize=9)

    fig.tight_layout()
    figure_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(figure_path, dpi=130)
    print(f"Figure saved successfully to: {figure_path.resolve()}")


def main():
    ap = argparse.ArgumentParser(description="Inspect and verify radar dataset")
    ap.add_argument("--dir", type=str, default="radar_dataset",
                    help="directory containing dataset files")
    ap.add_argument("--figure", type=str, default="radar_dataset/examples.png",
                    help="path to save inspection visualization")
    args = ap.parse_args()

    dataset_dir = Path(args.dir)
    print("====================================================")
    print("           RADAR DATASET INTEGRITY INSPECTION       ")
    print("====================================================\n")

    for split in ("train", "val", "test"):
        p = dataset_dir / f"{split}.npz"
        if p.exists():
            summarize(p)
        else:
            print(f"Warning: {p} does not exist!")

    plot_examples(dataset_dir, Path(args.figure))


if __name__ == "__main__":
    main()
