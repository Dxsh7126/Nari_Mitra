"""
sos_backend.py — Nari Mitra SOS Flask Backend
===============================================
Exposes a POST /sos endpoint. When the Flutter app's temporal voting confirms
aggression (2/3 windows exceed threshold), the app POSTs the list of emergency
contact numbers here. This server uses Twilio Programmable Voice to place a
separate outbound call to EVERY contact in the list simultaneously.

Environment Variables Required
-------------------------------
    TWILIO_ACCOUNT_SID          — Twilio Account SID (starts with AC...)
    TWILIO_AUTH_TOKEN           — Twilio Auth Token
    TWILIO_FROM_NUMBER          — Your Twilio phone number  e.g. +14155552671
    EMERGENCY_CONTACT_NUMBER    — Single-number fallback if 'contacts' not sent

Running — Local
---------------
    pip install flask twilio gunicorn
    python sos_backend.py

Running — Render (Cloud)
------------------------
    # Render sets $PORT automatically. Use gunicorn as the start command:
    gunicorn -w 2 -b 0.0.0.0:$PORT sos_backend:app
    #
    # In your Render dashboard → Settings → Start Command, enter exactly:
    #   gunicorn -w 2 -b 0.0.0.0:$PORT sos_backend:app
    #
    # Set these env vars in Render → Environment:
    #   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN,
    #   TWILIO_FROM_NUMBER, EMERGENCY_CONTACT_NUMBER

Request Format (POST /sos)
--------------------------
    Content-Type: application/json
    {
        "contacts": ["+919876543210", "+917654321098"],   # list of E.164 numbers
        "threat_score": 0.91,                              # optional — logged
        "votes": 3                                         # optional — logged
    }

    Legacy single-number format still accepted:
    { "to": "+919876543210" }

Response (200 OK)
-----------------
    {
        "status":    "calls_initiated",
        "call_sids": ["CAxxxxx", "CAyyyyy"],
        "failed":    []          # list of numbers that failed, if any
    }

Response (4xx / 5xx)
--------------------
    { "status": "error", "message": "<reason>" }
"""

import os
import time
import logging
import threading
import urllib.request
from flask import Flask, request, jsonify
from twilio.rest import Client
from twilio.twiml.voice_response import VoiceResponse

# ─── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("sos_backend")

# ─── App setup ────────────────────────────────────────────────────────────────
app = Flask(__name__)

# ─── Twilio credentials — always read from environment, never hardcoded ───────
TWILIO_ACCOUNT_SID       = os.environ.get("TWILIO_ACCOUNT_SID", "")
TWILIO_AUTH_TOKEN        = os.environ.get("TWILIO_AUTH_TOKEN", "")
TWILIO_FROM_NUMBER       = os.environ.get("TWILIO_FROM_NUMBER", "")
EMERGENCY_CONTACT_NUMBER = os.environ.get("EMERGENCY_CONTACT_NUMBER", "")


# ─── TwiML builder ────────────────────────────────────────────────────────────

def build_twiml() -> str:
    """
    Build the TwiML response delivered when the emergency contact answers.
    Voice: 'alice' — natural-sounding Twilio TTS, clear in noisy environments.
    Pauses between sentences aid comprehension under stress.
    """
    response = VoiceResponse()

    response.say("Emergency alert.", voice="alice", language="en-IN")
    response.pause(length=1)
    response.say("Your contact may be in danger.", voice="alice", language="en-IN")
    response.pause(length=1)
    response.say(
        "This is an automated message from Nari Mitra.",
        voice="alice",
        language="en-IN",
    )
    response.pause(length=1)
    response.say(
        "Please check on them immediately and call emergency services if needed.",
        voice="alice",
        language="en-IN",
    )

    return str(response)


# ─── Core call function ───────────────────────────────────────────────────────

def trigger_emergency_call(client: Client, to_number: str) -> str:
    """
    Initiate a single outbound Twilio Voice call to `to_number`.

    Parameters
    ----------
    client : Client
        Pre-constructed Twilio REST client (reused across the blast loop).
    to_number : str
        E.164-formatted target number, e.g. '+919876543210'.

    Returns
    -------
    str
        Twilio Call SID, e.g. 'CAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'.

    Raises
    ------
    Exception
        If the Twilio API call fails for this specific number.
    """
    call = client.calls.create(
        twiml=build_twiml(),
        to=to_number,
        from_=TWILIO_FROM_NUMBER,
    )
    log.info("Call initiated — SID: %s  →  %s", call.sid, to_number)
    return call.sid


# ─── /sos endpoint ────────────────────────────────────────────────────────────

@app.route("/sos", methods=["POST"])
def sos():
    """
    POST /sos
    Parses the list of emergency contacts, fires a separate Twilio call for
    each number concurrently (sequential loop — Twilio handles concurrency
    on its end), and returns all call SIDs.
    """
    data = request.get_json(silent=True) or {}

    # ── Resolve contact list ──────────────────────────────────────────────────
    # Prefer the new 'contacts' list; fall back to legacy 'to' field, then env.
    contacts: list[str] = data.get("contacts", [])

    if not contacts:
        # Legacy single-number fallback
        legacy = data.get("to", EMERGENCY_CONTACT_NUMBER).strip()
        if legacy:
            contacts = [legacy]

    if not contacts:
        log.warning("SOS request rejected — no contacts provided")
        return jsonify({
            "status": "error",
            "message": "No emergency contacts provided. "
                       "Send 'contacts' list or set EMERGENCY_CONTACT_NUMBER.",
        }), 400

    # Strip whitespace from every number
    contacts = [c.strip() for c in contacts if c.strip()]

    threat_score = data.get("threat_score", None)
    votes        = data.get("votes", None)
    log.info(
        "SOS blast triggered — contacts=%s  threat_score=%s  votes=%s",
        contacts, threat_score, votes,
    )

    # ── Validate Twilio credentials ───────────────────────────────────────────
    if not all([TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER]):
        msg = (
            "Twilio credentials incomplete. "
            "Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER."
        )
        log.error(msg)
        return jsonify({"status": "error", "message": msg}), 500

    client = Client(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)

    # ── Blast loop: call every contact ────────────────────────────────────────
    call_sids: list[str] = []
    failed:    list[dict] = []

    for number in contacts:
        try:
            sid = trigger_emergency_call(client, number)
            call_sids.append(sid)
        except Exception as exc:
            log.error("Failed to call %s: %s", number, exc)
            failed.append({"number": number, "error": str(exc)})

    # ── Response ──────────────────────────────────────────────────────────────
    if call_sids:
        return jsonify({
            "status":    "calls_initiated",
            "call_sids": call_sids,
            "failed":    failed,
        }), 200
    else:
        return jsonify({
            "status":  "error",
            "message": "All calls failed.",
            "failed":  failed,
        }), 500


# ─── Health check endpoint ────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def health():
    """Liveness probe. Returns credential readiness status."""
    creds_ok = all([TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER])
    return jsonify({
        "status":      "ok",
        "credentials": "configured" if creds_ok else "missing",
        "service":     "Nari Mitra SOS Backend",
    }), 200


# ─── Ping endpoint (ultra-lightweight — for keepalive only) ───────────────────

@app.route("/ping", methods=["GET"])
def ping():
    """
    Minimal liveness endpoint for the self-ping keepalive thread.
    Returns immediately with no credential checks or DB queries.
    Also suitable for external uptime monitors (UptimeRobot, etc.).
    """
    return jsonify({"status": "pong"}), 200


# ─── Self-ping keepalive — prevents Render free-tier spin-down ────────────────
#
# Render Free Tier sends SIGTERM after 15 minutes of zero inbound HTTP traffic.
# This thread pings /ping every 14 minutes, keeping the process alive.
# It reads RENDER_EXTERNAL_URL which Render injects automatically — no config
# needed. On local dev, the env var is absent and the thread simply does not
# start, so there is zero impact on local workflows.

def _keepalive_loop(ping_url: str, interval: int) -> None:
    """Background daemon: sleep interval seconds, then GET ping_url. Repeat."""
    while True:
        time.sleep(interval)
        try:
            with urllib.request.urlopen(ping_url, timeout=10) as resp:
                log.info("Keepalive ping OK — %s  (HTTP %d)", ping_url, resp.status)
        except Exception as exc:
            log.warning("Keepalive ping failed (will retry next cycle): %s", exc)


def _start_keepalive() -> None:
    """
    Spawn the keepalive daemon thread if RENDER_EXTERNAL_URL is set.
    Called once at module load time — safe for Gunicorn pre-fork workers
    because daemon threads are inherited per-worker after fork and each
    runs its own independent ping cycle.
    """
    render_url = os.environ.get("RENDER_EXTERNAL_URL", "").rstrip("/")
    if not render_url:
        log.info("RENDER_EXTERNAL_URL not set — keepalive thread not started (local mode).")
        return

    ping_url  = f"{render_url}/ping"
    # 14 minutes = 840 seconds (safely under the 15-minute spin-down threshold)
    interval  = int(os.environ.get("KEEPALIVE_INTERVAL_SECONDS", "840"))

    thread = threading.Thread(
        target=_keepalive_loop,
        args=(ping_url, interval),
        daemon=True,   # dies automatically when the worker receives SIGTERM
        name="keepalive",
    )
    thread.start()
    log.info(
        "Keepalive thread started — pinging %s every %d s",
        ping_url, interval,
    )


# Start keepalive at import time so it runs in every Gunicorn worker.
_start_keepalive()


# ─── Entry point (local dev only) ────────────────────────────────────────────
# In production, Gunicorn is the process that starts the app — this block
# is never executed on Render. It is retained solely for local development:
#   python sos_backend.py
#
# Render injects $PORT at runtime (currently 10000). Binding to 0.0.0.0
# is required so the container port is reachable from Render's reverse proxy.
# debug=False is mandatory — never enable debug mode in deployment.

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5001))
    log.info("Nari Mitra SOS backend starting on port %d", port)
    app.run(host="0.0.0.0", port=port, debug=False)
