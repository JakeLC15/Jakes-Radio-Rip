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

# Base port index to separate multiple streams on localhost
LOCAL_PORT=9000

for RAW_URL in "${STREAM_URLS[@]}"; do
    (
        FOLDER_NAME=$(echo "$RAW_URL" | awk -F/ '{print $3}')
        STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"
        mkdir -p "$STREAM_DIR"
        
        PORT=$LOCAL_PORT
        LOCAL_PORT=$((LOCAL_PORT + 1))

        SUCCESS=false
        for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
            echo "🔍 [Attempt $attempt/$MAX_RETRIES] Tracing redirected URL layout..."
            
            if curl -sLI --max-time 5 "$RAW_URL" -o /dev/null; then
                echo "✅ Connection verified! Building silent proxy server on port $PORT..."
                
                jq --arg key "$FOLDER_NAME" --arg val "Online" '. + {($key): $val}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
                
                # 1. Establish the silent loopback relay proxy.
                # Added >/dev/null 2>&1 to hide all netcat console logging entirely.
                (
                    while true; do
                        echo -e "HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nIcy-MetaData: 1\r\n\r\n" | nc -l -p "$PORT" -s 127.0.0.1 -w 5 >/dev/null 2>&1 || true
                        curl -sL -H "Icy-MetaData: 1" "$RAW_URL" | nc 127.0.0.1 "$PORT" >/dev/null 2>&1 || true
                        sleep 1
                    done
                ) &
                PROXY_PID=$!
                
                sleep 1

                # 2. Command streamripper to target the quiet local loopback address
                streamripper "http://127.0.0.1:$PORT/" -d "$STREAM_DIR" -a -q
                
                SUCCESS=true
                kill "$PROXY_PID" 2>/dev/null || true
                break
            else
                echo "⚠️ Connection failed on attempt $attempt for: $RAW_URL"
                if [ $attempt -lt $MAX_RETRIES ]; then
                    echo "⏳ Waiting $RETRY_DELAY seconds..."
                    sleep $RETRY_DELAY
                fi
            fi
        done

        if [ "$SUCCESS" = false ]; then
            echo "❌ ERROR: Max retries reached. Stream completely offline: $RAW_URL"
            jq --arg key "$FOLDER_NAME" --arg val "Offline" '. + {($key): $val}' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        fi
    ) &
done

wait
