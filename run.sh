#!/bin/bash
set -uo pipefail

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

        for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
            echo "🔍 [Attempt $attempt/$MAX_RETRIES] Validating: $URL..."

            if curl -fsS --max-time 5 "$URL" -o /dev/null; then

                mkdir -p "$STREAM_DIR"

                echo "✅ Stream active! Saving to: $STREAM_DIR"

                update_status "$FOLDER_NAME" "Online"

                streamripper "$URL" \
                    -d "$STREAM_DIR" \
                    -a \
                    --quiet

                SUCCESS=true
                break

            else
                echo "⚠️ Connection failed on attempt $attempt for: $URL"

                if [ $attempt -lt $MAX_RETRIES ]; then
                    echo "⏳ Waiting $RETRY_DELAY seconds before retrying..."
                    sleep "$RETRY_DELAY"
                fi
            fi
        done

        if [ "$SUCCESS" = false ]; then
            echo "❌ ERROR: Max retries reached. Stream is completely offline: $URL"
            update_status "$FOLDER_NAME" "Offline"
        fi

    ) &
done

wait
