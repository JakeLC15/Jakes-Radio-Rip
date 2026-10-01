#!/bin/bash
set -e

CONFIG_PATH="/data/options.json"
STATUS_FILE="/media/DATA2/Music/jakes_station_rip/status.json"

if [ -f "$CONFIG_PATH" ]; then
    BASE_OUTPUT_DIR=$(jq --raw-output '.output_dir // "/media/stationripper"' "$CONFIG_PATH")
    mapfile -t STREAM_URLS < <(jq --raw-output '.streams[] // empty' "$CONFIG_PATH")
fi

if [ ${#STREAM_URLS[@]} -eq 0 ]; then
    echo "❌ Error: No URLs found in your 'streams' configuration list!"
    exit 1
fi

mkdir -p "$BASE_OUTPUT_DIR"

# Initialize the tracking JSON file
echo "{}" > "$STATUS_FILE"

for URL in "${STREAM_URLS[@]}"; do
    FOLDER_NAME=$(echo "$URL" | awk -F/ '{print $3}')
    STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"
    
    echo "🔍 Validating: $URL..."
    
    if curl -sLI --max-time 5 "$URL" -o /dev/null; then
        mkdir -p "$STREAM_DIR"
        echo "✅ Stream active! Saving to: $STREAM_DIR"
        
        # Log status as Online
        jq --arg key "$FOLDER_NAME" --arg val "Online" '. + {($key): $val}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        
        streamripper "$URL" -d "$STREAM_DIR" -a &
    else
        echo "❌ ERROR: Could not connect to stream: $URL"
        # Log status as Offline
        jq --arg key "$FOLDER_NAME" --arg val "Offline" '. + {($key): $val}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    fi
done

wait

