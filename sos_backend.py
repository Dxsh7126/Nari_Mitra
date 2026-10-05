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
import logging
from flask import Flask, request, jsonify
from twilio.rest import Client
from twilio.twiml.voice_response import VoiceResponse
from datetime import datetime, timezone

# ─── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("sos_backend")

# ─── App setup ────────────────────────────────────────────────────────────────
app = Flask(__name__)
SOS_SESSIONS = {}
# ─── Twilio credentials — always read from environment, never hardcoded ───────
TWILIO_ACCOUNT_SID       = os.environ.get("TWILIO_ACCOUNT_SID", "")
TWILIO_AUTH_TOKEN        = os.environ.get("TWILIO_AUTH_TOKEN", "")
TWILIO_FROM_NUMBER       = os.environ.get("TWILIO_FROM_NUMBER", "")
EMERGENCY_CONTACT_NUMBER = os.environ.get("EMERGENCY_CONTACT_NUMBER", "")

#TESTING
TEST_MODE = os.environ.get("SOS_TEST_MODE", "false").lower() == "true"


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

@app.route("/gps-test",methods=["POST"])
def gps_test():
    data = request.get_json(silent=True) or {}

    print("\n========== GPS TEST ==========")
    print(f"🆔 Session ID: {data.get('session_id')}")
    print(f"📍 Location: {data.get('location')}")
    print("==============================\n")

    return jsonify({
        "status":"recieved",
        "session_id":data.get("session_id"),
        "location":data.get("location")
    }),200

@app.route("/sos", methods=["POST"])
def sos():
    """
    POST /sos
    Parses the list of emergency contacts, fires a separate Twilio call for
    each number concurrently (sequential loop — Twilio handles concurrency
    on its end), and returns all call SIDs.
    """
    data = request.get_json(silent=True) or {}

    print("\n========== SOS REQUEST ==========")
    print("📦 Raw data received:")
    print(data)

    session_id = data.get("session_id")
    location = data.get("location")

    print(f"🆔 Session ID: {session_id}")
    print(f"📍 Location: {location}")
    print("=================================\n")

    if session_id:
        SOS_SESSIONS[session_id] = {
            "session_id":session_id,
            "created_at":datetime.now(timezone.utc).isoformat(),
            "status":"active",
            "location":location
        }
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

    #TESTING
    if TEST_MODE:
        log.info("TEST MODE — no Twilio calls will be placed.")
        log.info("Session ID: %s", session_id)
        log.info("Location: %s", location)

        return jsonify({
            "status": "test_received",
            "session_id": session_id,
            "location": location,
            "contacts_received": contacts,
            "threat_score": threat_score,
            "votes": votes,
            "call_sids": [],
        }), 200


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


@app.route("/track/<session_id>", methods=["GET"])
def track(session_id):
    session = SOS_SESSIONS.get(session_id)

    if not session:
        return jsonify({
            "status":"error",
            "message":"SOS session not found",
        }),404

    return jsonify({
        "status":"ok",
        "session":session
    }),200

# ─── Health check endpoint ────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def health():
    """Liveness probe. Returns credential readiness status."""
    creds_ok = all([TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER])
    log.info(
        "Credential check — SID=%s TOKEN=%s FROM=%s",
        bool(TWILIO_ACCOUNT_SID),
        bool(TWILIO_AUTH_TOKEN),
        bool(TWILIO_FROM_NUMBER),
    )
    return jsonify({
        "status":      "ok",
        "credentials": "configured" if creds_ok else "missing",
        "service":     "Nari Mitra SOS Backend",
    }), 200


# ─── Ping endpoint — for external uptime monitors ────────────────────────────
# Point UptimeRobot (or any equivalent service) at GET /ping every 14 minutes
# to prevent Render free-tier spin-down. Returns immediately with no
# credential checks or database queries.

@app.route("/ping", methods=["GET"])
def ping():
    """Minimal liveness endpoint for external uptime monitors."""
    return jsonify({"status": "pong"}), 200


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
