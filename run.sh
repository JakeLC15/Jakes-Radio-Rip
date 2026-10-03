#!/bin/bash

echo "========================================"
echo "JAKE'S STATION RIPPER STARTING"
echo "BUILD TEST: 2026-10-03-5"
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
    
    # Read the frontend logging toggle option (defaults to false)
    LOGGING_ENABLED=$(jq --raw-output '.logging // false' "$CONFIG_PATH")

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

# --- STATUS FUNCTION ---
update_status() {
    local key="$1"
    local value="$2"
    (
        flock 200
        TMP_FILE="${STATUS_FILE}.$$"
        if jq --arg key "$key" --arg val "$value" '. + {($key): $val}' "$STATUS_FILE" > "$TMP_FILE"; then
            mv "$TMP_FILE" "$STATUS_FILE"
        else
            rm -f "$TMP_FILE"
            echo "⚠️ Failed to update status for $key"
        fi
    ) 200>"$STATUS_LOCK"
}

# --- MANUAL REUSABLE PURGE FUNCTION ---
run_duplicate_cleanup() {
    echo "🧹 Starting manual duplicate purge..."
    find "$BASE_OUTPUT_DIR" -type f -name "*.mp3" | grep -E "\([0-9]+\)\.mp3$" | tr '\n' '\0' | xargs -0 rm -f
    echo "✅ Duplicate purge complete!"
}

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

            # DYNAMIC LOGGING CONTROL:
            # Respects user toggle state
            if [ "${LOGGING_ENABLED}" = "true" ]; then
                streamripper \
                    "$URL" \
                    -d "$STREAM_DIR" \
                    -u "WinampMPEG/5.0"
            else
                # Completely silences stream metadata tracking
                streamripper \
                    "$URL" \
                    -d "$STREAM_DIR" \
                    -u "WinampMPEG/5.0" \
                    --quiet
            fi

            RC=$?

            update_status "$FOLDER_NAME" "Offline"

            [ "$RC" -eq 0 ] && break
            sleep "$RETRY_DELAY"
        done
    ) &
done

# --- INGRESS WEB SERVICE HANDLING ---
handle_web_request() {
    local request_file="$1"
    
    # Listen for browser button post actions
    if grep -q "POST /cleanup" "$request_file"; then
        run_duplicate_cleanup
        echo -e "HTTP/1.1 303 See Other\r\nLocation: .\r\n\r\n"
        return
    fi

    # Calculate real-time counts and list arrays on hit execution
    local current_count=$(find "$BASE_OUTPUT_DIR" -type f -name "*.mp3" | wc -l | tr -d ' ')
    local station_rows=""
    if [ -f "$STATUS_FILE" ]; then
        station_rows=$(jq -r 'to_entries | .[] | "<li><strong>\(.key):</strong> <span>\(.value)</span></li>"' "$STATUS_FILE")
    fi

    cat <<EOF
HTTP/1.1 200 OK
Content-Type: text/html; charset=UTF-8
Connection: close

<!DOCTYPE html>
<html>
<head>
    <title>Jake's Station Ripper</title>
    <style>
        body { font-family: -apple-system, sans-serif; background: #111; color: #eee; padding: 20px; }
        .card { background: #222; padding: 20px; border-radius: 8px; max-width: 500px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }
        h2 { margin-top: 0; color: #03a9f4; }
        ul { list-style: none; padding: 0; }
        li { padding: 10px 0; border-bottom: 1px solid #333; display: flex; justify-content: space-between; }
        button { background: #ff9800; color: white; border: none; padding: 12px 20px; font-weight: bold; border-radius: 4px; cursor: pointer; width: 100%; font-size: 14px; }
        button:hover { background: #e68a00; }
        .count { font-size: 24px; font-weight: bold; color: #4caf50; margin: 10px 0; }
    </style>
</head>
<body>
    <div class="card">
        <h2>📻 Live Stream Status</h2>
        <ul>
            ${station_rows:-<li>No active streams found</li>}
        </ul>
    </div>
    <div class="card">
        <h2>📊 Library Management</h2>
        <p>Total Tracks Ripped:</p>
        <div class="count">${current_count} tracks</div>
        <form action="cleanup" method="POST">
            <button type="submit">🧹 Purge Numbered Duplicates</button>
        </form>
    </div>
</body>
</html>
EOF
}

# --- FOREGROUND EVENT SERVICE CAPTURE LOOP ---
echo "🚀 Ingress Web Management Dashboard running on port 8099..."
trap 'kill $(jobs -p) 2>/dev/null; exit 0' SIGINT SIGTERM

# Lightweight network mapping socket loop
while true; do
    TMP_REQ=$(mktemp)
    nc -l -p 8099 > "$TMP_REQ" < <(handle_web_request "$TMP_REQ")
    rm -f "$TMP_REQ"
done
