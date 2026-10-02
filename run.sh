#!/bin/bash
set -e

CONFIG_PATH="/data/options.json"
STATUS_FILE="/media/DATA2/Music/jakes_station_rip/status.json"
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

for URL in "${STREAM_URLS[@]}"; do
    # Extract domain name safely by wrapping the source string
    FOLDER_NAME=$(echo "$URL" | awk -F/ '{print $3}')
    STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"
    
    (
        SUCCESS=false
        for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
            echo "🔍 [Attempt $attempt/$MAX_RETRIES] Validating: $URL..."
            
            # Wrap variables in double quotes to prevent the semicolon from splitting the shell command
            if curl -sLI --max-time 5 "$URL" -o /dev/null; then
                mkdir -p "$STREAM_DIR"
                echo "✅ Stream active! Saving to: $STREAM_DIR"
                
                jq --arg key "$FOLDER_NAME" --arg val "Online" '. + {($key): $val}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
                
                # Executing streamripper with clean quiet string variables
                streamripper "$URL" -d "$STREAM_DIR" -a -q
                SUCCESS=true
                break
            else
                echo "⚠️ Connection failed on attempt $attempt for: $URL"
                if [ $attempt -lt $MAX_RETRIES ]; then
                    echo "⏳ Waiting $RETRY_DELAY seconds before retrying..."
                    sleep $RETRY_DELAY
                fi
            fi
        done

        if [ "$SUCCESS" = false ]; then
            echo "❌ ERROR: Max retries reached. Stream offline: $URL"
            jq --arg key "$FOLDER_NAME" --arg val "Offline" '. + {($key): $val}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        fi
    ) &
done

wait
