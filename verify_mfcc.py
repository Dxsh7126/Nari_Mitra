"""
Quick verification: run this script to see what librosa produces for MFCC
on a sine wave, then compare with the Dart output at the same signal.

Run from the project root:
  cd d:\pyton\Nari_Shakti
  .venv\Scripts\activate
  python verify_mfcc.py

This tells us if the Dart MFCC implementation matches librosa.
"""
import numpy as np
import librosa

SAMPLE_RATE = 16000
N_MFCC = 40

# A 440 Hz sine wave for 1 second — easy to replicate in any language
t = np.linspace(0, 1, SAMPLE_RATE, endpoint=False)
audio = (0.5 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)

# Compute MFCC exactly as in training
mfcc = librosa.feature.mfcc(y=audio, sr=SAMPLE_RATE, n_mfcc=N_MFCC)
mfcc_T = mfcc.T  # [time_frames, 40]

print(f"MFCC shape: {mfcc_T.shape}")
print(f"Frames: {mfcc_T.shape[0]}")
print(f"\nRaw MFCC stats (before normalization):")
print(f"  Global mean: {np.mean(mfcc_T):.4f}")
print(f"  Global std:  {np.std(mfcc_T):.4f}")
print(f"  Min: {np.min(mfcc_T):.4f}, Max: {np.max(mfcc_T):.4f}")

# Apply same normalization as training
TRAIN_MEAN = -19.785846710205078
TRAIN_STD  = 145.11888122558594
mfcc_norm = (mfcc_T - TRAIN_MEAN) / (TRAIN_STD + 1e-8)

print(f"\nNormalized MFCC stats:")
print(f"  Global mean: {np.mean(mfcc_norm):.4f}")
print(f"  Global std:  {np.std(mfcc_norm):.4f}")

print(f"\nFirst frame, first 5 coefficients (raw):")
print(f"  {mfcc_T[0, :5]}")

# Run inference on the normalized MFCC
import tensorflow as tf
interpreter = tf.lite.Interpreter(model_path="flutter_app/assets/aggression_model.tflite")
interpreter.allocate_tensors()
inp = interpreter.get_input_details()
out = interpreter.get_output_details()

# Trim/pad to 32 frames
features = mfcc_norm
if features.shape[0] > 32:
    features = features[:32]
elif features.shape[0] < 32:
    features = np.pad(features, ((0, 32 - features.shape[0]), (0, 0)))

input_data = np.expand_dims(features, axis=0).astype(np.float32)
interpreter.set_tensor(inp[0]['index'], input_data)
interpreter.invoke()
score = float(interpreter.get_tensor(out[0]['index'])[0][0])
print(f"\nModel score for 440Hz sine: {score:.5f}")
print("(Should be < 0.5 — sine wave is clearly not aggression)")
print("\nNow check the aggressive_mfcc.json inference:")

import json
with open("flutter_app/assets/aggressive_mfcc.json") as f:
    agg_data = json.load(f)
agg_arr = np.array(agg_data, dtype=np.float32)
agg_input = np.expand_dims(agg_arr, axis=0)
interpreter.set_tensor(inp[0]['index'], agg_input)
interpreter.invoke()
agg_score = float(interpreter.get_tensor(out[0]['index'])[0][0])
print(f"  Aggressive JSON score: {agg_score:.5f}  (expected > 0.5)")

with open("flutter_app/assets/normal_mfcc.json") as f:
    norm_data = json.load(f)
norm_arr = np.array(norm_data, dtype=np.float32)
norm_input = np.expand_dims(norm_arr, axis=0)
interpreter.set_tensor(inp[0]['index'], norm_input)
interpreter.invoke()
norm_score = float(interpreter.get_tensor(out[0]['index'])[0][0])
print(f"  Normal JSON score:     {norm_score:.5f}  (expected < 0.5)")
