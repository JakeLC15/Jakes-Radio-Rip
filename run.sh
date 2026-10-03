#!/bin/bash

echo "========================================"
echo "JAKE'S STATION RIPPER STARTING"
echo "BUILD TEST: 2026-10-03-2"
echo "========================================"

set -uo pipefail

echo "Streamripper:"
streamripper --version || true

echo "========================================"

CONFIG_PATH="/data/options.json"
MAX_RETRIES=5
RETRY_DELAY=10

LOGGING_ENABLED="false" 
BASE_OUTPUT_DIR="/media/stationripper"

if [ -f "$CONFIG_PATH" ]; then
    BASE_OUTPUT_DIR=$(jq --raw-output '.output_dir // "/media/stationripper"' "$CONFIG_PATH")
    LOGGING_ENABLED=$(jq --raw-output '.logging // true' "$CONFIG_PATH")
    mapfile -t STREAM_URLS < <(jq --raw-output '.streams[] // empty' "$CONFIG_PATH")
fi

if [ ${#STREAM_URLS[@]} -eq 0 ]; then
    echo "❌ Error: No URLs found in your 'streams' configuration list!"
    exit 1
fi

mkdir -p "$BASE_OUTPUT_DIR"

STATUS_FILE="${BASE_OUTPUT_DIR}/status.json"
STATUS_LOCK="${BASE_OUTPUT_DIR}/status.lock"

echo "{}" > "$STATUS_FILE"

# --- NEW: POST DIRECTLY TO HOME ASSISTANT API ---
post_to_ha() {
    local entity_id="$1"
    local state="$2"
    local json_attributes="${3:-{}}"

    # Home Assistant automatically provides SUPERVISOR_TOKEN and http://supervisor/core/api/
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        curl -s -X POST \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"state\": \"${state}\", \"attributes\": ${json_attributes}}" \
            "http://supervisor/core/api/states/${entity_id}" > /dev/null || true
    fi
}

# --- UPDATED STATUS FUNCTION ---
update_status() {
    local key="$1"
    local value="$2"
    (
        flock 200
        TMP_FILE="${STATUS_FILE}.$$"
        if jq --arg key "$key" --arg val "$value" '. + {($key): $val}' "$STATUS_FILE" > "$TMP_FILE" then
            mv "$TMP_FILE" "$STATUS_FILE"
            
            # Instantly push the entire status JSON string to your HA sensor!
            local full_json=$(cat "$STATUS_FILE" | jq -c '.')
            post_to_ha "sensor.station_ripper_status" "${full_json}" '{"friendly_name": "Station Ripper Status"}'
        else
            rm -f "$TMP_FILE"
            echo "⚠️ Failed to update status for $key"
        fi
    ) 200>"$STATUS_LOCK"
}

# --- NEW: MUSIC FILE COUNTER FUNCTION ---
update_music_count() {
    # Count the tracks recursively inside the chosen path
    local count=$(find "$BASE_OUTPUT_DIR" -type f -name "*.mp3" | wc -l | tr -d ' ')
    
    # Broadcast the numeric value straight to Home Assistant
    post_to_ha "sensor.ripped_music_count" "$count" '{"friendly_name": "Ripped Music Count", "unit_of_measurement": "tracks"}'
}

run_duplicate_cleanup() {
    echo "🧹 Starting manual duplicate purge..."
    find "$BASE_OUTPUT_DIR" -type f -name "*.mp3" | grep -E "\([0-9]+\)\.mp3$" | tr '\n' '\0' | xargs -0 rm -f
    echo "✅ Duplicate purge complete!"
    update_music_count # Recount immediately after a purge
}

QUIET_FLAG=""
if [ "$LOGGING_ENABLED" != "true" ]; then
    QUIET_FLAG="--quiet"
fi

# Run initial count on startup
update_music_count

# Background rip threads
for URL in "${STREAM_URLS[@]}"; do
    FOLDER_NAME=$(echo "$URL" | awk -F/ '{print $3}')
    [ -z "$FOLDER_NAME" ] && FOLDER_NAME="stream"
    STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"

    (
        for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
            echo "Starting Streamripper for $FOLDER_NAME..."
            mkdir -p "$STREAM_DIR"
            update_status "$FOLDER_NAME" "Ripping"

            streamripper "$URL" -d "$STREAM_DIR" -u "WinampMPEG/5.0" ${QUIET_FLAG:-}
            RC=$?

            update_status "$FOLDER_NAME" "Offline"
            
            # Recount files since a track boundary was likely hit or stream disconnected
            update_music_count

            [ "$RC" -eq 0 ] && break
            sleep "$RETRY_DELAY"
        done
    ) &
done

# Foreground Event loop
echo "🚀 Jake's Station Ripper listener active. Awaiting dashboard actions..."
counter=0
trap 'echo "Stopping..."; kill $(jobs -p) 2>/dev/null; exit 0' SIGINT SIGTERM

while true; do
    if read -t 2 -r line; then
        if [ "$line" = "run_cleanup" ]; then
            run_duplicate_cleanup
        fi
    fi

    # Every 10 minutes (300 cycles of 2-second timeouts), refresh file count sensor
    case $counter in
        300) update_music_count; counter=0 ;;
        *)   counter=$((counter + 1)) ;;
    esac

    if [ $(jobs -r | wc -l) -eq 0 ]; then
        echo "❌ All background radio streams have stopped working. Exiting Add-on."
        exit 1
    fi
done
