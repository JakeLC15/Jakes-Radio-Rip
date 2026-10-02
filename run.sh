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

for RAW_URL in "${STREAM_URLS[@]}"; do
    (
        # 1. Resolve Redirections: Run a pre-flight trace to catch the final destination stream URL
        # -s (silent), -L (follow locations), -I (fetch headers only), grep catches the location, awk cleans it up
        echo "🔍 Tracing redirection links for: $RAW_URL"
        FINAL_URL=$(curl -sIL -o /dev/null -w "%{url_effective}" "$RAW_URL")
        
        # Fallback to the raw URL if curl returns empty strings
        URL="${FINAL_URL:-$RAW_URL}"
        
        # 2. Convert Secure Strings: Standard streamripper does not support https:// protocol headers.
        # If the stream got redirected to a secure path, we change 'https' back to 'http' so the binary can read it.
        if [[ "$URL" =~ ^https:// ]]; then
            echo "🔒 Secure stream detected. Rewriting to insecure http for streamripper compatibility..."
            URL=$(echo "$URL" | sed 's/^https:/http:/')
        fi

        FOLDER_NAME=$(echo "$URL" | awk -F/ '{print $3}')
        STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"
        
        SUCCESS=false
        for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
            echo "🔍 [Attempt $attempt/$MAX_RETRIES] Connecting directly to resolved target: $URL..."
            
            if curl -sLI --max-time 5 "$URL" -o /dev/null; then
                mkdir -p "$STREAM_DIR"
                echo "✅ Target resolved and active! Saving files to: $STREAM_DIR"
                
                jq --arg key "$FOLDER_NAME" --arg val "Online" '. + {($key): $val}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
                
                # Hand off the final, verified destination URL path directly to the streamripper engine
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
            echo "❌ ERROR: Max retries reached. Stream completely offline: $URL"
            jq --arg key "$FOLDER_NAME" --arg val "Offline" '. + {($key): $val}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        fi
    ) &
done

wait
