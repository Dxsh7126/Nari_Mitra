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
from flask import Flask, request, jsonify, render_template_string
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

    log.info("🆔 SOS SESSION CREATED: %s", session_id)
    log.info("📍 Initial location: %s", location)
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
            "session_id": session_id,
            "message": "All calls failed.",
            "failed":  failed,
        }), 500

@app.route("/track/<session_id>",methods=["POST"])
def update_tracking_location(session_id):
    """
        Recieve a new GPS position for an active SOS session.
    """

    session = SOS_SESSIONS.get(session_id)

    if not session:
        return jsonify({
            "status":"error",
            "message":"SOS session not found"
        }),404

    if session['status'] != "active":
        return jsonify({
            "status":"error",
            "message":"SOS session is no longer active"
        }), 410

    data = request.get_json(silent=True) or {}

    location = data.get("location")

    if not location:
        return jsonify({
            "status":"error",
            "message":"Location is required"
        }), 400

    latitude = location.get("latitude")
    longitude = location.get("longitude")
    accuracy = location.get("accuracy")

    if latitude is None and longitude is None:
        return jsonify({
            "status":"error",
            "message":"Longitude and Latitude are required"
        }), 400

    session["location"] = {
        "latitude":latitude,
        "longitude":longitude,
        "accuracy":accuracy
    }

    session["last_updated"] = datetime.now(timezone.utc).isoformat()

    log.info(
        "📍 Location updated — session=%s lat=%s lng=%s accuracy=%s",
        session_id,
        latitude,
        longitude,
        accuracy,
    )

    return jsonify({
        "status": "location_updated",
        "session_id": session_id,
        "location": session["location"],
        "last_updated": session["last_updated"],
    }), 200


@app.route("/track/<session_id>", methods=["GET"])
def tracking_page(session_id):

    session = SOS_SESSIONS.get(session_id)

    if not session:
        return """
        <!DOCTYPE html>
        <html>
        <body style="font-family:Arial;text-align:center;padding:40px;">
            <h2>❌ SOS session not found</h2>
            <p>This tracking session may have expired or does not exist.</p>
        </body>
        </html>
        """, 404

    return render_template_string("""
    <!DOCTYPE html>
    <html>
    <head>

        <meta name="viewport"
            content="width=device-width, initial-scale=1.0">

        <title>Nari Mitra — Live SOS</title>

        <link
            rel="stylesheet"
            href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
        />

        <style>

            * {
                box-sizing: border-box;
            }

            body {
                margin: 0;
                font-family: Arial, sans-serif;
                background: #111;
                color: white;
            }

            #header {
                padding: 14px 16px;
                background: #b00020;
            }

            #header h2 {
                margin: 0;
                font-size: 19px;
            }

            #header p {
                margin: 5px 0 0;
                font-size: 13px;
                opacity: 0.9;
            }

            #map {
                height: 65vh;
                width: 100%;
            }

            #info {
                background: #181818;
                padding: 16px;
            }

            .row {
                display: flex;
                justify-content: space-between;
                padding: 7px 0;
                border-bottom: 1px solid #333;
            }

            .label {
                color: #aaa;
            }

            .value {
                font-weight: bold;
            }

            #status {
                margin-top: 10px;
                font-size: 13px;
                color: #aaa;
            }

            #navigate {
                width: 100%;
                margin-top: 14px;
                padding: 14px;
                border: none;
                border-radius: 8px;
                background: #1976d2;
                color: white;
                font-size: 16px;
                font-weight: bold;
            }

            #navigate:disabled {
                background: #555;
            }

        </style>

    </head>

    <body>

    <div id="header">

        <h2>🚨 NARI MITRA — SOS ACTIVE</h2>

        <p>
            Live emergency tracking
        </p>

    </div>

    <div id="map"></div>

    <div id="info">

        <div class="row">
            <span class="label">Victim</span>
            <span class="value" id="victimStatus">
                Locating...
            </span>
        </div>

        <div class="row">
            <span class="label">Distance</span>
            <span class="value" id="distance">
                —
            </span>
        </div>

        <div class="row">
            <span class="label">Direction</span>
            <span class="value" id="direction">
                —
            </span>
        </div>

        <div class="row">
            <span class="label">Location accuracy</span>
            <span class="value" id="accuracy">
                —
            </span>
        </div>

        <div id="status">
            Getting your location...
        </div>

        <button id="navigate" disabled>
            🧭 START NAVIGATION
        </button>

    </div>


    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js">
    </script>

    <script>

    const sessionId = "{{ session_id }}";

    let victimLocation = null;
    let contactLocation = null;

    let victimMarker = null;
    let contactMarker = null;
    let routeLine = null;


    // --------------------------------------------------
    // MAP
    // --------------------------------------------------

    const map = L.map("map").setView(
        [20.5937, 78.9629],
        5
    );

    L.tileLayer(
        "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
        {
            maxZoom: 19,
            attribution: "&copy; OpenStreetMap contributors"
        }
    ).addTo(map);


    // --------------------------------------------------
    // VICTIM LOCATION
    // --------------------------------------------------

    async function updateVictimLocation() {

        try {

            const response = await fetch(
                `/track/${sessionId}/location`
            );

            const data = await response.json();

            if (data.status !== "active") {

                document.getElementById("status").innerText =
                    "⚠️ SOS session is no longer active.";

                return;
            }

            if (!data.location) {
                return;
            }

            victimLocation = {
                latitude: data.location.latitude,
                longitude: data.location.longitude,
                accuracy: data.location.accuracy
            };

            document.getElementById("victimStatus").innerText =
                "LIVE";

            document.getElementById("accuracy").innerText =
                data.location.accuracy
                    ? `±${data.location.accuracy.toFixed(1)} m`
                    : "Unknown";


            const latLng = [
                victimLocation.latitude,
                victimLocation.longitude
            ];


            if (!victimMarker) {

                victimMarker = L.marker(latLng)
                    .addTo(map)
                    .bindPopup("🚨 Victim");

                map.setView(latLng, 16);

            } else {

                victimMarker.setLatLng(latLng);

            }

            calculateNavigation();

        } catch (error) {

            console.error(
                "Victim location error:",
                error
            );

        }
    }


    // --------------------------------------------------
    // CONTACT LOCATION
    // --------------------------------------------------

    function startContactTracking() {

        if (!navigator.geolocation) {

            document.getElementById("status").innerText =
                "❌ Your browser does not support GPS.";

            return;
        }


        navigator.geolocation.watchPosition(

            function(position) {

                contactLocation = {

                    latitude: position.coords.latitude,

                    longitude: position.coords.longitude
                };


                const latLng = [
                    contactLocation.latitude,
                    contactLocation.longitude
                ];


                if (!contactMarker) {

                    contactMarker = L.marker(latLng)
                        .addTo(map)
                        .bindPopup("👤 You");

                } else {

                    contactMarker.setLatLng(latLng);

                }


                document.getElementById("status").innerText =
                    "📍 Your location is being tracked for navigation.";


                calculateNavigation();

            },

            function(error) {

                console.error(
                    "Contact GPS error:",
                    error
                );

                document.getElementById("status").innerText =
                    "⚠️ Please allow location access to enable navigation.";

            },

            {
                enableHighAccuracy: true,
                maximumAge: 5000,
                timeout: 10000
            }

        );

    }


    // --------------------------------------------------
    // DISTANCE
    // --------------------------------------------------

    function calculateDistance(
        lat1,
        lon1,
        lat2,
        lon2
    ) {

        const R = 6371000;

        const dLat =
            (lat2 - lat1) * Math.PI / 180;

        const dLon =
            (lon2 - lon1) * Math.PI / 180;


        const a =
            Math.sin(dLat / 2) ** 2 +
            Math.cos(lat1 * Math.PI / 180) *
            Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) ** 2;


        const c =
            2 * Math.atan2(
                Math.sqrt(a),
                Math.sqrt(1 - a)
            );


        return R * c;

    }


    // --------------------------------------------------
    // BEARING
    // --------------------------------------------------

    function calculateBearing(
        lat1,
        lon1,
        lat2,
        lon2
    ) {

        const φ1 = lat1 * Math.PI / 180;
        const φ2 = lat2 * Math.PI / 180;

        const Δλ =
            (lon2 - lon1) * Math.PI / 180;


        const y =
            Math.sin(Δλ) * Math.cos(φ2);

        const x =
            Math.cos(φ1) * Math.sin(φ2) -
            Math.sin(φ1) *
            Math.cos(φ2) *
            Math.cos(Δλ);


        let bearing =
            Math.atan2(y, x) * 180 / Math.PI;


        bearing = (bearing + 360) % 360;

        return bearing;

    }


    function bearingToDirection(bearing) {

        const directions = [
            "N",
            "NE",
            "E",
            "SE",
            "S",
            "SW",
            "W",
            "NW"
        ];

        return directions[
            Math.round(bearing / 45) % 8
        ];

    }


    // --------------------------------------------------
    // NAVIGATION
    // --------------------------------------------------

    function calculateNavigation() {

        if (!victimLocation || !contactLocation) {
            return;
        }


        const distance = calculateDistance(

            contactLocation.latitude,
            contactLocation.longitude,

            victimLocation.latitude,
            victimLocation.longitude

        );


        const bearing = calculateBearing(

            contactLocation.latitude,
            contactLocation.longitude,

            victimLocation.latitude,
            victimLocation.longitude

        );


        document.getElementById("distance").innerText =
            distance < 1000
                ? `${Math.round(distance)} m`
                : `${(distance / 1000).toFixed(2)} km`;


        document.getElementById("direction").innerText =
            `${bearingToDirection(bearing)} (${Math.round(bearing)}°)`;


        document.getElementById("navigate").disabled = false;

    }


    // --------------------------------------------------
    // INITIALIZATION
    // --------------------------------------------------

        startContactTracking();

        updateVictimLocation();


        // Victim updates every 5 seconds on the webpage.
        // The victim phone itself is sending every ~10 seconds.

        setInterval(
            updateVictimLocation,
            5000
        );

        </script>

        </body>
        </html>
        """, session_id=session_id)

@app.route("/track/<session_id>/location",methods=["GET"])
def get_tracking_location(session_id):
    session = SOS_SESSIONS.get(session_id)

    if not session:
        return jsonify({
            "status": "error",
            "message": "SOS session not found."
        }), 404

    if session["status"] != "active":
        return jsonify({
            "status": "ended",
            "location": session.get("location"),
        }), 200

    return jsonify({
        "status": "active",
        "session_id": session_id,
        "location": session.get("location"),
        "last_updated": session.get("last_updated"),
    }), 200

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
