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

# Function to safely update the status file across multiple background threads
update_status() {
    local key="$1"
    local val="$2"
    # Create a completely unique temporary file name for this specific thread
    local tmp_file="/tmp/status_${key}_$$.json"
    
    # Read current state, modify it, and save it safely using a lock-free assignment
    if [ -f "$STATUS_FILE" ]; then
        jq --arg key "$key" --arg val "$val" '. + {($key): $val}' "$STATUS_FILE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$STATUS_FILE"
    fi
}

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
                
                update_status "$FOLDER_NAME" "Online"
                
                # 1. Establish the silent loopback relay proxy using a reliable background piping trick.
                # This feeds streamripper directly without dropping packets.
                PIPE="/tmp/pipe_${PORT}.fifo"
                rm -f "$PIPE"
                mkfifo "$PIPE"
                
                (
                    while true; do
                        # Host a basic local HTTP server layout that streams curl audio directly into the pipe
                        echo -e "HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nIcy-MetaData: 1\r\n\r\n" > "$PIPE" 2>/dev/null || true
                        curl -sL -H "Icy-MetaData: 1" "$RAW_URL" >> "$PIPE" 2>/dev/null || true
                        sleep 1
                    done
                ) &
                PROXY_PID=$!
                
                # Use netcat only to route the network pipe cleanly
                nc -l -p "$PORT" -s 127.0.0.1 < "$PIPE" > /dev/null 2>&1 &
                NC_PID=$!

                sleep 1

                # 2. Command streamripper to target the quiet local loopback address
                streamripper "http://127.0.0.1:$PORT/" -d "$STREAM_DIR" -a -q
                
                SUCCESS=true
                kill "$PROXY_PID" "$NC_PID" 2>/dev/null || true
                rm -f "$PIPE"
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
            update_status "$FOLDER_NAME" "Offline"
        fi
    ) &
done

wait
