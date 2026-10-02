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

update_status() {
    local key="$1"
    local val="$2"
    local tmp_file="/tmp/status_${key}_$$.json"
    
    if [ -f "$STATUS_FILE" ]; then
        jq --arg key "$key" --arg val "$val" '. + {($key): $val}' "$STATUS_FILE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$STATUS_FILE"
    fi
}

# Print a single startup layout message
echo "📂 StationRipper initialized. Monitoring ${#STREAM_URLS[@]} stream(s)..."

for RAW_URL in "${STREAM_URLS[@]}"; do
    (
        URL="$RAW_URL"
        FOLDER_NAME=$(echo "$URL" | awk -F/ '{print $3}')
        STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"
        
        SUCCESS=false
        for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
            # curl validation check runs completely silently
            if curl -sLI --max-time 5 "$URL" -o /dev/null; then
                mkdir -p "$STREAM_DIR"
                echo "🟢 Stream Active: $FOLDER_NAME -> Saving to subfolder"
                
                update_status "$FOLDER_NAME" "Online"
                
                # FIXED: Added >/dev/null 2>&1 to swallow standard terminal headers and banner text completely
                streamripper "$URL" -d "$STREAM_DIR" -a -q >/dev/null 2>&1
                SUCCESS=true
                break
            else
                if [ $attempt -lt $MAX_RETRIES ]; then
                    sleep $RETRY_DELAY
                fi
            fi
        done

        if [ "$SUCCESS" = false ]; then
            echo "🔴 Stream Offline: Connection failed for $FOLDER_NAME"
            update_status "$FOLDER_NAME" "Offline"
        fi
    ) &
done

wait
