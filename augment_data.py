"""
augment_data.py — Nari Shakti Data Augmentation Pipeline
=========================================================
Iterates through Mozilla Common Voice audio clips, overlays UrbanSound8K
background noise, applies audiomentations transforms, extracts MFCC features
(matching the on-device Dart pipeline exactly), and saves augmented .wav files
alongside NumPy MFCC arrays for retraining.

Usage
-----
    python augment_data.py \
        --voice_dir   data/common_voice/clips \
        --noise_dir   data/UrbanSound8K/audio \
        --out_wav_dir data/augmented/wav \
        --out_npy_dir data/augmented/mfcc \
        --n_augments  5

Dependencies
------------
    pip install librosa audiomentations soundfile numpy tqdm
"""

import os
import argparse
import warnings
import numpy as np
import librosa
import soundfile as sf
from pathlib import Path
from tqdm import tqdm
from audiomentations import (
    Compose,
    AddGaussianNoise,
    TimeStretch,
    PitchShift,
    Shift,
    AddBackgroundNoise,
)

warnings.filterwarnings("ignore", category=UserWarning)

# ─── Training-time normalisation constants (must match Dart extractor) ─────────
TRAIN_MEAN = -19.785846710205078
TRAIN_STD  = 145.11888122558594

# ─── MFCC config (must mirror mfcc_extractor.dart exactly) ────────────────────
SR        = 16_000      # target sample rate
N_MFCC    = 40          # number of MFCC coefficients
N_FFT     = 2048        # FFT window size
HOP_LEN   = 512         # hop length
N_MELS    = 128         # mel filterbank bands
FMIN      = 0.0         # min frequency
FMAX      = 8000.0      # max frequency  (SR/2)
DURATION  = 1.0         # seconds per window
N_FRAMES  = 32          # expected time frames [32 × 40]


# ─── Augmentation pipeline ─────────────────────────────────────────────────────

def build_augmenter(noise_dir: str | None) -> Compose:
    """
    Build the audiomentations Compose pipeline.

    If a valid UrbanSound8K audio directory is provided, AddBackgroundNoise
    is included as an additional transform. Otherwise only the four core
    transforms are applied (still sufficient for robust augmentation).
    """
    transforms = [
        AddGaussianNoise(
            min_amplitude=0.001,
            max_amplitude=0.015,
            p=0.5,
        ),
        TimeStretch(
            min_rate=0.8,
            max_rate=1.25,
            p=0.5,
        ),
        PitchShift(
            min_semitones=-3,
            max_semitones=3,
            p=0.5,
        ),
        Shift(
            min_shift=-0.5,
            max_shift=0.5,
            p=0.5,
        ),
    ]

    if noise_dir and os.path.isdir(noise_dir):
        transforms.append(
            AddBackgroundNoise(
                sounds_path=noise_dir,
                min_snr_db=5.0,
                max_snr_db=20.0,
                p=0.6,
            )
        )
        print(f"[augmenter] UrbanSound8K noise loaded from: {noise_dir}")
    else:
        print("[augmenter] No valid noise_dir — skipping AddBackgroundNoise.")

    return Compose(transforms)


# ─── Feature extraction ────────────────────────────────────────────────────────

def extract_mfcc(audio: np.ndarray, sr: int = SR) -> np.ndarray:
    """
    Extract normalised MFCC matrix from a 1-second audio clip.

    Returns
    -------
    np.ndarray, shape (N_FRAMES, N_MFCC) = (32, 40)
        Normalised using global training-time mean/std — identical to what
        the Dart mfcc_extractor.dart produces after z-score normalisation.
    """
    # Pad or trim to exactly 1 second
    target_len = int(sr * DURATION)
    if len(audio) < target_len:
        audio = np.pad(audio, (0, target_len - len(audio)))
    else:
        audio = audio[:target_len]

    mfcc = librosa.feature.mfcc(
        y=audio,
        sr=sr,
        n_mfcc=N_MFCC,
        n_fft=N_FFT,
        hop_length=HOP_LEN,
        n_mels=N_MELS,
        fmin=FMIN,
        fmax=FMAX,
        norm="ortho", 
        htk=False,         
    )  # shape: (N_MFCC, time_frames)

    # Transpose → (time_frames, N_MFCC) then trim/pad to N_FRAMES
    mfcc = mfcc.T  # (time, coeffs)
    if mfcc.shape[0] < N_FRAMES:
        pad = N_FRAMES - mfcc.shape[0]
        mfcc = np.pad(mfcc, ((0, pad), (0, 0)))
    else:
        mfcc = mfcc[:N_FRAMES, :]  # (32, 40)

    # Global z-score normalisation — must match TRAIN_MEAN / TRAIN_STD
    mfcc = (mfcc - TRAIN_MEAN) / TRAIN_STD

    return mfcc.astype(np.float32)


# ─── Core augmentation loop ────────────────────────────────────────────────────

def augment_file(
    audio_path: str,
    augmenter: Compose,
    out_wav_dir: str,
    out_npy_dir: str,
    n_augments: int = 5,
) -> int:
    """
    Load one audio file, produce n_augments augmented variants, save each as:
      - A valid 16kHz mono PCM-16 .wav file
      - A (32, 40) float32 .npy MFCC array

    Returns the number of variants successfully written.
    """
    try:
        # Load the WHOLE file (remove duration)
        audio, _ = librosa.load(audio_path, sr=SR, mono=True)
        # Trim the dead air at the beginning
        audio, _ = librosa.effects.trim(audio, top_db=20)
    except Exception as exc:
        print(f"  [SKIP] {audio_path}: {exc}")
        return 0

    stem = Path(audio_path).stem
    written = 0

    for i in range(n_augments):
        try:
            aug_audio = augmenter(samples=audio, sample_rate=SR)

            # ── Save augmented WAV ────────────────────────────────────────────
            wav_name = f"{stem}_aug{i:02d}.wav"
            wav_path = os.path.join(out_wav_dir, wav_name)
            sf.write(wav_path, aug_audio, SR, subtype="PCM_16")

            # ── Save MFCC numpy array ─────────────────────────────────────────
            mfcc = extract_mfcc(aug_audio)
            npy_name = f"{stem}_aug{i:02d}.npy"
            npy_path = os.path.join(out_npy_dir, npy_name)
            np.save(npy_path, mfcc)

            written += 1
        except Exception as exc:
            print(f"  [ERR] {audio_path} aug={i}: {exc}")

    return written


def run_pipeline(
    voice_dir: str,
    noise_dir: str | None,
    out_wav_dir: str,
    out_npy_dir: str,
    n_augments: int = 5,
    extensions: tuple = (".wav", ".mp3", ".ogg", ".flac"),
):
    """
    Main pipeline entry point. Walks voice_dir recursively, processes every
    audio file, and writes augmented outputs to out_wav_dir / out_npy_dir.
    """
    os.makedirs(out_wav_dir, exist_ok=True)
    os.makedirs(out_npy_dir, exist_ok=True)

    # Collect all audio files
    audio_files = [
        str(p)
        for p in Path(voice_dir).rglob("*")
        if p.suffix.lower() in extensions
    ]

    if not audio_files:
        print(f"[ERROR] No audio files found in: {voice_dir}")
        return

    print(f"\n{'─'*60}")
    print(f"  Nari Shakti — Data Augmentation Pipeline")
    print(f"{'─'*60}")
    print(f"  Source clips   : {len(audio_files)}")
    print(f"  Augments each  : {n_augments}")
    print(f"  Total expected : {len(audio_files) * n_augments}")
    print(f"  Output WAV     : {out_wav_dir}")
    print(f"  Output NPY     : {out_npy_dir}")
    print(f"{'─'*60}\n")

    augmenter = build_augmenter(noise_dir)

    total_written = 0
    for audio_path in tqdm(audio_files, desc="Augmenting", unit="file"):
        total_written += augment_file(
            audio_path, augmenter, out_wav_dir, out_npy_dir, n_augments
        )

    print(f"\n[Done] {total_written} augmented samples written.")
    print(f"  WAV → {out_wav_dir}")
    print(f"  NPY → {out_npy_dir}")
    print("\nNext step: use the .npy files as training input for retraining")
    print("the CNN model. Each array has shape (32, 40) and is already")
    print("z-score normalised with the global training statistics.\n")


# ─── CLI entry point ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Nari Shakti — audio data augmentation pipeline"
    )
    parser.add_argument(
        "--voice_dir",
        default="data/common_voice/clips",
        help="Root directory containing Mozilla Common Voice .wav/.mp3 clips",
    )
    parser.add_argument(
        "--noise_dir",
        default="data/UrbanSound8K/audio",
        help="Root directory of UrbanSound8K audio (for AddBackgroundNoise)",
    )
    parser.add_argument(
        "--out_wav_dir",
        default="data/augmented/wav",
        help="Output directory for augmented .wav files",
    )
    parser.add_argument(
        "--out_npy_dir",
        default="data/augmented/mfcc",
        help="Output directory for MFCC .npy arrays",
    )
    parser.add_argument(
        "--n_augments",
        type=int,
        default=5,
        help="Number of augmented variants to generate per source clip (default: 5)",
    )

    args = parser.parse_args()
    run_pipeline(
        voice_dir=args.voice_dir,
        noise_dir=args.noise_dir,
        out_wav_dir=args.out_wav_dir,
        out_npy_dir=args.out_npy_dir,
        n_augments=args.n_augments,
    )
