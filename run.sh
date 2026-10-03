#!/bin/bash

echo "========================================"
echo "JAKE'S STATION RIPPER STARTING"
echo "BUILD TEST: 2026-10-03-1"
echo "========================================"

set -uo pipefail

echo "Streamripper:"
streamripper --version || true

echo "========================================"

CONFIG_PATH="/data/options.json"
MAX_RETRIES=5
RETRY_DELAY=10
LOGGING_ENABLED="false" 

if [ -f "$CONFIG_PATH" ]; then
    BASE_OUTPUT_DIR=$(jq --raw-output '.output_dir // "/media/stationripper"' "$CONFIG_PATH")
    
    # Read the frontend logging toggle option (defaults to true)
    LOGGING_ENABLED=$(jq --raw-output '.logging // true' "$CONFIG_PATH")

    mapfile -t STREAM_URLS < <(
        jq --raw-output '.streams[] // empty' "$CONFIG_PATH"
    )
fi

if [ ${#STREAM_URLS[@]} -eq 0 ]; then
    echo "❌ Error: No URLs found in your 'streams' configuration list!"
    exit 1
fi

mkdir -p "$BASE_OUTPUT_DIR"

STATUS_FILE="${BASE_OUTPUT_DIR}/status.json"
STATUS_LOCK="${BASE_OUTPUT_DIR}/status.lock"

echo "{}" > "$STATUS_FILE"

update_status() {
    local key="$1"
    local value="$2"
    (
        flock 200
        TMP_FILE="${STATUS_FILE}.$$"
        if jq --arg key "$key" --arg val "$value" '. + {($key): $val}' "$STATUS_FILE" > "$TMP_FILE" then
            mv "$TMP_FILE" "$STATUS_FILE"
        else
            rm -f "$TMP_FILE"
            echo "⚠️ Failed to update status for $key"
        fi
    ) 200>"$STATUS_LOCK"
}

QUIET_FLAG=""
if [ "$LOGGING_ENABLED" != "true" ]; then
    QUIET_FLAG="--quiet"
fi

for URL in "${STREAM_URLS[@]}"; do

    FOLDER_NAME=$(echo "$URL" | awk -F/ '{print $3}')
    if [ -z "$FOLDER_NAME" ]; then
        FOLDER_NAME="stream"
    fi

    STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"

    (
        for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do

            # These core script logs will ALWAYS print for ease of basic troubleshooting
            echo ""
            echo "========================================"
            echo "[$FOLDER_NAME] Attempt $attempt/$MAX_RETRIES"
            echo "URL: $URL"
            echo "Output: $STREAM_DIR"
            echo "========================================"
            echo "Starting Streamripper..."

            mkdir -p "$STREAM_DIR"
            update_status "$FOLDER_NAME" "Ripping"

            # Executing streamripper with the dynamic flag. 
            # ${QUIET_FLAG:-} prevents 'set -u' from crashing if the variable is empty.
            streamripper \
                "$URL" \
                -d "$STREAM_DIR" \
                -u "WinampMPEG/5.0" \
                ${QUIET_FLAG:-}

            RC=$?

            echo "Streamripper exited with code: $RC"

            if [ "$RC" -eq 0 ]; then
                update_status "$FOLDER_NAME" "Offline"
                break
            fi

            echo "⚠️ Streamripper failed for $FOLDER_NAME"
            update_status "$FOLDER_NAME" "Offline"

            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                echo "⏳ Waiting $RETRY_DELAY seconds before retrying..."
                sleep "$RETRY_DELAY"
            fi

        done
        
        echo "❌ $FOLDER_NAME stopped after $MAX_RETRIES attempts"

    ) &
done

wait
