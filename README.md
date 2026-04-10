<div align="center">

# 🛡️ Nari Mitra

### *AI-Powered Women's Safety — Edge Intelligence, Zero Cloud Dependency for Detection*

[![Flutter](https://img.shields.io/badge/Flutter-3.10%2B-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Python](https://img.shields.io/badge/Python-3.9%2B-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://python.org)
[![TensorFlow Lite](https://img.shields.io/badge/TFLite-Edge%20AI-FF6F00?style=for-the-badge&logo=tensorflow&logoColor=white)](https://tensorflow.org/lite)
[![Deployed on Render](https://img.shields.io/badge/Deployed%20on-Render-46E3B7?style=for-the-badge&logo=render&logoColor=white)](https://render.com)
[![Twilio](https://img.shields.io/badge/Twilio-Voice%20API-F22F46?style=for-the-badge&logo=twilio&logoColor=white)](https://twilio.com)

**A real-time acoustic aggression detector with a 10-second failsafe and a simultaneous multi-contact emergency voice blast — all within ~14 seconds of a single tap.**

</div>

---

## 📖 Overview

Nari Mitra is a Flutter-based Android safety application that uses a lightweight on-device CNN to classify the acoustic environment in real time. All threat detection runs **entirely on the device** — no audio is ever transmitted to a server during inference. The cloud layer is invoked only at the exact moment a confirmed emergency requires action: placing simultaneous voice calls to every registered emergency contact.

The system is built around two core principles:

1. **Privacy by architecture** — raw audio never leaves the device during detection.
2. **Reliability over connectivity** — the entire detection pipeline works with zero network access.

---

## ✨ Features

| Feature | Description |
|---|---|
| 🎯 **Single-Tap Radar Button** | One tap starts a full 3-second analysis cycle. Animated pulsing radar provides real-time feedback. |
| 🧠 **Edge AI Inference** | 47 KB quantised TFLite CNN runs fully on-device. No cloud ML, no latency, no privacy risk. |
| 🎛️ **Dual-Gate Audio Filter** | RMS Silence Gate + Zero Crossing Rate filter reject silence and non-speech before inference — preserves battery. |
| 🗳️ **Temporal Majority Voting** | 2-of-3 window vote required to confirm aggression — cuts false positives by ~40%. |
| ⏱️ **10-Second Failsafe Buffer** | Confirmed aggression triggers a high-visibility countdown with double-pulse vibration. User can cancel false alarms at any point. |
| 📞 **Multi-Contact SOS Blast** | Simultaneous Twilio voice calls placed to all registered emergency contacts the moment the countdown expires. |
| 🎙️ **Stealth Evidence Recorder** | 30-second background WAV recording begins silently at SOS trigger — saved to Android's sandboxed `ApplicationDocumentsDirectory`. |
| 🔒 **Evidence Vault** | In-app browser to review, play back, and delete all recorded evidence files with decoded timestamps. |
| 👥 **Native Contact Picker** | Selects emergency contacts directly from the device address book via the OS-native picker. |
| ☁️ **Render Cloud Backend** | Flask + Gunicorn backend handles Twilio credential proxying securely. |
| 💓 **UptimeRobot Keepalive** | External cron pings `/ping` every 14 minutes to prevent Render free-tier cold starts. |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                 ANDROID DEVICE  (No internet for detection)     │
│                                                                 │
│   [Single-Tap]  ──▶  FlutterSoundRecorder  (3 sec @ 16 kHz)   │
│                              │                                  │
│                    WAV Splitter (Dart)                          │
│                    3 × 1-second windows                         │
│                              │                                  │
│              ┌───────────────▼──────────────────┐              │
│              │  RMS Gate  ·  ZCR Gate           │  pre-filter  │
│              │  Pure-Dart MFCC Extractor         │  [32 × 40]  │
│              └───────────────┬──────────────────┘              │
│                              │                                  │
│              ┌───────────────▼──────────────────┐              │
│              │  TFLite CNN  (47 KB)             │              │
│              │  Sigmoid output  ∈ [0, 1]        │              │
│              └───────────────┬──────────────────┘              │
│                              │                                  │
│                  2-of-3 Temporal Majority Vote                  │
│                              │                                  │
│       ┌──────────────────────▼────────────────────────┐        │
│       │   10-Second Countdown  +  Haptic Vibration    │        │
│       │   [ ✅  I AM SAFE — CANCEL ]                  │        │
│       └──────────────────────┬────────────────────────┘        │
│                              │  Timer expires                   │
│           Future.wait() — fires both concurrently               │
│        ┌─────────────────────┴──────────────────────┐          │
│        │                                            │          │
│  🎙️ Stealth Recorder                        📡 HTTP POST       │
│  evidence_<ts>.wav                          /sos  →  Render    │
│  ApplicationDocumentsDirectory                                  │
│  30 s · sandboxed · invisible                                   │
└─────────────────────────────────────────────────────────────────┘
                                      │ HTTPS
                  ┌───────────────────▼───────────────────┐
                  │  Render  ·  Gunicorn  ·  Flask        │
                  │  POST /sos                             │
                  │  for number in contacts:              │
                  │      twilio.calls.create()            │
                  │  → { call_sids: [...] }               │
                  └───────────────────┬───────────────────┘
                                      │
                          ┌───────────▼──────────┐
                          │  Twilio Voice API    │
                          │  Outbound call blast │
                          │  "Emergency alert.   │
                          │   Your contact may   │
                          │   be in danger..."   │
                          └──────────────────────┘
```

**End-to-end latency: ~14 seconds** from single tap to emergency contacts' phones ringing.

---

## 🔬 The ML Pipeline

### Model

| Parameter | Value |
|---|---|
| Architecture | 1D Convolutional Neural Network |
| Parameters | ~12,000 |
| Input shape | `[1, 32, 40]` — (batch, time frames, MFCC coefficients) |
| Output | Sigmoid scalar ∈ [0, 1] — aggression probability |
| Training data | RAVDESS emotional speech (480 clips) + 5× augmentation |
| Accuracy | ~82% on augmented real-world test set |
| Export format | TFLite with DEFAULT post-training quantisation |
| Model size | **47 KB** |
| Inference time | ~10 ms per window on mid-range Android |

### Augmentation Pipeline (`augment_data.py`)

Studio recordings don't generalise to real-world phone microphones. A 5× augmentation pipeline using `audiomentations` expands the training corpus:

| Transform | Effect |
|---|---|
| `AddGaussianNoise` | Simulates crowd / street ambience |
| `TimeStretch` (0.8–1.25×) | Handles speech rate variation |
| `PitchShift` (±3 semitones) | Accounts for voice pitch variation |
| `Shift` (±50%) | Simulates recording onset variation |
| `AddBackgroundNoise` (UrbanSound8K) | Real-world noise overlay at 5–20 dB SNR |

### Feature Extraction — Pure Dart MFCC

The on-device MFCC extractor is a complete from-scratch Dart port of `librosa.feature.mfcc()` — no native plugin, no Python bridge. The 8-stage pipeline:

```
PCM-16 bytes → Float normalisation → Hann window (periodic)
→ STFT (n_fft=2048, hop=512) → Power spectrogram
→ Slaney-norm Mel filterbank (128 bands, 0–8 kHz)
→ Log compression → Orthonormal DCT-II (40 coefficients)
→ Global z-score normalisation (μ=−19.786, σ=145.119)
```

Validated against librosa reference output to within `|Δ| < 0.001` per frame.

### Audio Gates (Battery Optimisation)

Before MFCC extraction runs, two signal gates filter out frames that cannot contain meaningful speech:

| Gate | Threshold | Rejects |
|---|---|---|
| RMS Silence | `rms < 0.01` | Silence, very quiet ambient sound |
| ZCR Low | `zcr < 0.005` | Constant hum, AC noise, tones |
| ZCR High | `zcr > 0.45` | Broadband noise, wideband interference |

---

## 📱 App Screens

### Safety Dashboard
- **Pulsing radar animation** — three concentric rings animate at 2.2 s idle / 0.9 s active, colour-coded by state (violet → amber → green/red)
- **Status card** — animated colour transition between: idle / listening / safe / aggression confirmed
- **Per-window score bars** — three `LinearProgressIndicator` bars with live aggression percentages
- **Sensitivity slider** — real-time threshold adjustment (0.30–0.95)
- **Evidence Vault entry** — one-tap access to recorded evidence
- **Trusted contacts** — up to 3 contacts from native address book

### SOS Countdown Dialog
- Full-screen danger border, `CircularProgressIndicator` countdown ring
- Double-pulse haptic pattern `[0, 400, 150, 400, 150, 400]` repeating every second
- Full-width 64 px green **"I AM SAFE — CANCEL"** button — maximum target size for stressed interaction

### Evidence Vault
- Lists all `evidence_*.wav` files sorted newest-first
- Displays decoded timestamp (`DD/MM/YYYY HH:MM:SS`) and file size
- Native `audioplayers` playback with live `mm:ss` progress bar
- Deletion with confirmation dialog

---

## ☁️ Backend

### `sos_backend.py` — Flask + Gunicorn on Render

The backend exists as a **secure credential proxy**. Embedding Twilio credentials in a compiled APK is a critical security flaw — they are extractable via standard reverse-engineering tools. The Flask server holds all secrets in environment variables; the app knows only the HTTPS endpoint URL.

**Endpoints:**

| Method | Route | Purpose |
|---|---|---|
| `POST` | `/sos` | Receives contacts list, fires Twilio call blast |
| `GET` | `/health` | Liveness probe with credential check |
| `GET` | `/ping` | Minimal ping for UptimeRobot keepalive |

**Request format:**
```json
{
  "contacts": ["+919876543210", "+917654321098"],
  "threat_score": 0.917,
  "votes": 3
}
```

**Response:**
```json
{
  "status": "calls_initiated",
  "call_sids": ["CA3f2d...", "CA7a19..."],
  "failed": []
}
```

### Why Phone Calls Over Push Notifications

A ringing phone demands attention. A push notification can be silenced passively, dismissed reflexively, or missed entirely. A call persists until answered or timed out and activates a deeply conditioned human urgency response — critical when the contact may be driving, in a meeting, or in a noisy environment.

The TwiML message uses deliberate 1-second pauses between short sentences to ensure comprehension even if the contact answers mid-message:

> *"Emergency alert. [pause] Your contact may be in danger. [pause] This is an automated message from Nari Mitra. [pause] Please check on them immediately and call emergency services if needed."*

### Cold-Start Fix — UptimeRobot

Render's free tier sends `SIGTERM` after 15 minutes of zero inbound traffic. A self-ping keepalive thread inside the app caused a deadlock (single Gunicorn worker blocking itself). The correct solution is **external**: UptimeRobot pings `GET /ping` every 14 minutes. The endpoint returns `{"status": "pong"}` immediately — no credential checks, no Twilio interaction.

---

## 🛠️ Tech Stack

### Mobile (Flutter / Dart)

| Package | Version | Role |
|---|---|---|
| `tflite_flutter` | `^0.12.0` | On-device CNN inference, interpreter lifecycle |
| `flutter_sound` | `^9.28.0` | PCM-16 WAV recording at 16 kHz; stealth evidence capture |
| `fftea` | `^1.5.0` | Pure Dart FFT for STFT computation in MFCC extractor |
| `audioplayers` | `^6.0.0` | Evidence Vault WAV playback via `DeviceFileSource` |
| `flutter_contacts` | `^1.1.9+2` | Native OS address book picker; E.164 phone resolution |
| `shared_preferences` | `^2.3.3` | Persistent contact name/phone storage |
| `vibration` | `^2.0.0` | Looping haptic pattern during SOS countdown |
| `http` | `^1.4.0` | Single HTTPS POST to Flask `/sos` endpoint |
| `path_provider` | `^2.1.5` | Resolves `ApplicationDocumentsDirectory` for sandboxed evidence |
| `permission_handler` | `^11.4.0` | Runtime `RECORD_AUDIO`, `READ_CONTACTS`, `VIBRATE` permissions |

### Backend (Python)

| Library | Version | Role |
|---|---|---|
| `Flask` | `3.1.0` | REST API framework |
| `gunicorn` | `23.0.0` | Production WSGI server |
| `twilio` | `9.4.3` | Programmable Voice outbound call API |

### ML / Data

| Tool | Role |
|---|---|
| `TensorFlow / Keras` | CNN model training |
| `TFLite Converter` | Post-training quantisation and `.tflite` export |
| `librosa` | MFCC extraction during training |
| `audiomentations` | 5× data augmentation pipeline |
| `RAVDESS Dataset` | Primary emotional speech training corpus |
| `UrbanSound8K` | Background noise for augmentation |

### Infrastructure

| Service | Role |
|---|---|
| **Render** | Flask backend hosting (Web Service) |
| **Twilio Programmable Voice** | Outbound emergency voice calls |
| **UptimeRobot** | External `/ping` cron — prevents Render cold starts |

---

## 🚀 Setup & Installation

### Prerequisites

- Flutter SDK ≥ 3.10.0 · Dart ≥ 3.0
- Android SDK (minSdkVersion 21 / Android 5.0)
- Python 3.9+ with pip
- Twilio account (verified phone number)
- Render account (free tier works)

### 1 — Flutter App

```bash
cd flutter_app
flutter pub get
flutter run
```

**Android permissions** — already declared in `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.VIBRATE"/>
<uses-permission android:name="android.permission.READ_CONTACTS"/>
```

### 2 — Python Backend

```bash
pip install -r requirements.txt
python sos_backend.py          # local dev (port 5001)
```

**Production (Render Start Command):**
```
gunicorn -w 1 -b 0.0.0.0:$PORT sos_backend:app
```

### 3 — Environment Variables (Render Dashboard → Environment)

```bash
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your_auth_token_here
TWILIO_FROM_NUMBER=+1xxxxxxxxxx
EMERGENCY_CONTACT_NUMBER=+91xxxxxxxxxx   # fallback if contacts list not sent
```

### 4 — Flutter → Render URL

Update `_sosBackendUrl` in `flutter_app/lib/main.dart`:
```dart
// TODO: Replace with your actual Render service URL after deploying
static const String _sosBackendUrl = 'https://<your-service>.onrender.com/sos';
```

### 5 — UptimeRobot Keepalive

Create a free monitor at [uptimerobot.com](https://uptimerobot.com):
- **Type:** HTTP(s)
- **URL:** `https://<your-service>.onrender.com/ping`
- **Interval:** 14 minutes

### 6 — Data Augmentation (optional retraining)

```bash
python augment_data.py \
  --voice_dir   data/common_voice/clips \
  --noise_dir   data/UrbanSound8K/audio \
  --out_wav_dir data/augmented/wav \
  --out_npy_dir data/augmented/mfcc \
  --n_augments  5
```

---

## 📁 Repository Structure

```
Nari_Shakti/
│
├── flutter_app/
│   ├── lib/
│   │   ├── main.dart              # UI dashboard, radar, countdown dialog, Evidence Vault
│   │   ├── audio_model.dart       # TFLite inference engine, temporal voting
│   │   ├── mfcc_extractor.dart    # Pure-Dart MFCC (librosa-equivalent)
│   │   └── sos_service.dart       # Future.wait() SOS coordinator, JSON payload
│   ├── assets/
│   │   ├── aggression_model.tflite  # 47 KB quantised CNN
│   │   ├── aggressive_mfcc.json     # Reference MFCC for parity validation
│   │   └── normal_mfcc.json         # Reference MFCC for parity validation
│   ├── android/
│   │   └── app/src/main/
│   │       └── AndroidManifest.xml  # Runtime permissions
│   └── pubspec.yaml               # Dart dependency graph + asset declarations
│
├── sos_backend.py                 # Flask /sos · /health · /ping endpoints
├── requirements.txt               # Flask==3.1.0 · twilio==9.4.3 · gunicorn==23.0.0
├── augment_data.py                # 5× audio augmentation pipeline
├── verify_mfcc.py                 # Dart ↔ Python MFCC parity validation
├── testing.ipynb                  # Model training & evaluation notebook
└── README.md
```

---

## ⏱️ End-to-End Latency

| Stage | Duration |
|---|---|
| Audio recording (3-second buffer) | 3,000 ms |
| WAV splitting + MFCC extraction (×3) | ~80 ms |
| TFLite inference (×3 windows) | ~30 ms |
| 10-second failsafe countdown | 10,000 ms |
| `Future.wait()` — recorder start + HTTP POST | ~400–800 ms |
| Twilio call initiation per contact | ~200 ms |
| **Total: tap → emergency contacts' phones ring** | **~13.5–14.5 s** |

---

## 🔮 Future Roadmap

- [ ] **Zero-Touch Safe Word Activation** — hands-free SOS trigger via user-defined spoken keyword using on-device wake-word detection; enables SOS when the phone is out of reach or inaccessible
- [ ] **AES-256 Evidence Encryption** — local encryption for all stealth recordings before storage
- [ ] **Background Continuous Monitoring** — passive detection loop without requiring manual tap
- [ ] **Power Profiling** — mAh benchmarking of background MFCC extraction; RMS gate tuning for all-day viability
- [ ] **Precision / Recall Hardening** — validation of ZCR gate and CNN against diverse urban backgrounds (traffic, crowds, construction)
- [ ] **Evidence Vault Sharing** — secure export workflow for sharing recordings with authorities

---

## 👥 Team

| Member | Role |
|---|---|
| **Daksh Anand** | ML Engineering, TFLite Edge Integration, Backend Architecture & End-to-End Integration |
| **Aryan Suvarna** | Project Research, Twilio API Integration & Cloud Deployment |
| **Riva Khajuria** | UI/UX Design & Flutter Frontend Implementation |

**Supervisor:** Dr. Anamika Dhillon  
**Institution:** Manipal University Jaipur — Dept. of AI & ML  
**Programme:** B.Tech CSE (AIML) · AIM2170 PBL-I · 2025–2026

---

<div align="center">

*Nari Mitra — Because safety should never depend on a network connection.*

</div>
