#!/bin/bash

echo "========================================"
echo "JAKE'S STATION RIPPER STARTING"
echo "BUILD TEST: 2026-10-01-2"
echo "========================================"

set -uo pipefail

echo "Streamripper:"
streamripper --version || true

STATUS_FILE="/media/DATA2/Music/jakes_station_rip/status.json"
STATUS_LOCK="/media/DATA2/Music/jakes_station_rip/status.lock"
CONFIG_PATH="/data/options.json"
MAX_RETRIES=5
RETRY_DELAY=10

if [ -f "$CONFIG_PATH" ]; then
    BASE_OUTPUT_DIR=$(jq --raw-output '.output_dir // "/media/stationripper"' "$CONFIG_PATH")
    mapfile -t STREAM_URLS < <(jq --raw-output '.streams[] // empty' "$CONFIG_PATH")
fi

if [ ${#STREAM_URLS[@]} -eq 0 ]; then
    echo "❌ Error: No URLs found in your 'streams' configuration list!"
    exit 1
fi

mkdir -p "$BASE_OUTPUT_DIR"
echo "{}" > "$STATUS_FILE"

update_status() {
    local key="$1"
    local value="$2"

    (
        flock 200

        jq --arg key "$key" --arg val "$value" \
            '. + {($key): $val}' \
            "$STATUS_FILE" > "${STATUS_FILE}.tmp"

        mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

    ) 200>"$STATUS_LOCK"
}

for URL in "${STREAM_URLS[@]}"; do
    FOLDER_NAME=$(echo "$URL" | awk -F/ '{print $3}')
    STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"

    (
        SUCCESS=false

        echo ""
        echo "========================================"
        echo "STARTING:"
        echo "$URL"
        echo "========================================"

        mkdir -p "$STREAM_DIR"

        echo "Starting Streamripper..."

        update_status "$FOLDER_NAME" "Online"

        streamripper "$URL" \
            -d "$STREAM_DIR" \
            \ -a \
            --quiet

        RC=$?

        echo "Streamripper exited with code $RC"

        if [ "$RC" -eq 0 ]; then
            SUCCESS=true
        fi

        if [ "$SUCCESS" = false ]; then
            echo "❌ Streamripper failed for: $URL"
            update_status "$FOLDER_NAME" "Offline"
        fi

    ) &
done

wait
