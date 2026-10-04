#!/bin/bash

echo "========================================"
echo "JAKE'S STATION RIPPER STARTING"
echo "BUILD TEST: 2026-10-04-1"
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

            if [ "${LOGGING_ENABLED}" = "true" ]; then
                streamripper \
                    "$URL" \
                    -d "$STREAM_DIR" \
                    -u "WinampMPEG/5.0" \
                    --no-cue
            else
                streamripper \
                    "$URL" \
                    -d "$STREAM_DIR" \
                    -u "WinampMPEG/5.0" \
                    --quiet \
                    --no-cue
            fi

            RC=$?
            update_status "$FOLDER_NAME" "Offline"

            [ "$RC" -eq 0 ] && break
            sleep "$RETRY_DELAY"
        done
    ) &
done

# --- PYTHON-BASED MULTI-THREADED INGRESS ENGINE ---
echo "🚀 Starting Ingress Web UI engine on port 8099..."

# Write a tiny Python handler engine on the fly that dynamically queries bash commands
cat << 'EOF' > /tmp/server.py
import os
import subprocess
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

BASE_OUTPUT_DIR = os.environ.get("BASE_OUTPUT_DIR", "/media/stationripper")
STATUS_FILE = os.environ.get("STATUS_FILE", f"{BASE_OUTPUT_DIR}/status.json")

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle requests in separate threads to stop connection lockups."""
    daemon_threads = True

class IngressHandler(BaseHTTPRequestHandler):
    def _render_page(self):
        try:
            count_res = subprocess.run(f"find '{BASE_OUTPUT_DIR}' -type f -name '*.mp3' | wc -l", shell=True, capture_output=True, text=True)
            current_count = count_res.stdout.strip()
        except:
            current_count = "0"

        station_rows = ""
        if os.path.exists(STATUS_FILE):
            try:
                with open(STATUS_FILE, 'r') as f:
                    data = json.load(f)
                for station, status in data.items():
                    station_rows += f"<li><strong>{station}:</strong> <span>{status}</span></li>"
            except:
                pass
        
        if not station_rows:
            station_rows = "<li>No active streams found</li>"

        clean_sub_path = BASE_OUTPUT_DIR.replace("/media/", "", 1).strip("/")
        
        if not clean_sub_path:
            target_media_url = "/media-browser/browser/app,media-source:%2F%2Fmedia_source%2Flocal%2F."
        else:
            url_safe_subfolders = clean_sub_path.replace("/", "%2F")
            target_media_url = f"/media-browser/browser/app,media-source:%2F%2Fmedia_source%2Flocal%2F{url_safe_subfolders}"

        return f"""<!DOCTYPE html>
<html>
<head>
    <title>Jake's Station Ripper</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #111; color: #eee; padding: 20px; }}
        .card {{ background: #222; padding: 20px; border-radius: 8px; max-width: 500px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }}
        h2 {{ margin-top: 0; color: #03a9f4; }}
        ul {{ list-style: none; padding: 0; }}
        li {{ padding: 10px 0; border-bottom: 1px solid #333; display: flex; justify-content: space-between; }}
        button {{ display: block; text-align: center; color: white; border: none; padding: 12px 20px; font-weight: bold; border-radius: 4px; cursor: pointer; width: 100%; font-size: 14px; margin-bottom: 16px; box-sizing: border-box; }}
        .btn-refresh {{ background: #03a9f4; }}
        .btn-refresh:hover {{ background: #0288d1; }}
        .btn-media {{ background: #4caf50; }}
        .btn-media:hover {{ background: #43a047; }}
        .btn-purge {{ background: #ff9800; margin-bottom: 0; }}
        .btn-purge:hover {{ background: #e68a00; }}
        .count {{ font-size: 24px; font-weight: bold; color: #4caf50; margin: 10px 0 20px 0; }}
        .form-container {{ display: block; margin-top: 16px; }}
    </style>
</head>
<body>
    <div class="card">
        <h2>📻 Live Stream Status</h2>
        <ul>{station_rows}</ul>
    </div>
    <div class="card">
        <h2>📊 Library Management</h2>
        <p>Total Tracks Ripped:</p>
        <div class="count">{current_count} tracks</div>
        
        <button class="btn-refresh" onclick="window.location.reload();">🔄 Refresh Live Data</button>
        
        <button class="btn-media" onclick="window.parent.history.pushState(null, '', '{target_media_url}'); window.parent.dispatchEvent(new PopStateEvent('popstate'));">📁 Open Media Browser</button>
        
        <form method="POST" class="form-container">
            <button type="submit" class="btn-purge">🧹 Purge Numbered Duplicates</button>
        </form>
    </div>
</body>
</html>"""

    def do_POST(self):
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length > 0:
                self.rfile.read(content_length)
        except Exception:
            pass

        cmd = f"find '{BASE_OUTPUT_DIR}' -type f -name '*.mp3' | grep -E '\\([0-9]+\\)\\.mp3$' | tr '\\n' '\\0' | xargs -0 rm -f"
        subprocess.run(cmd, shell=True)
        
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=UTF-8')
        self.end_headers()
        
        html = self._render_page()
        self.wfile.write(html.encode('utf-8'))

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=UTF-8')
        self.end_headers()
        
        html = self._render_page()
        self.wfile.write(html.encode('utf-8'))

if __name__ == '__main__':
    server = ThreadedHTTPServer(('0.0.0.0', 8099), IngressHandler)
    server.serve_forever()
EOF

# Export environment paths to python sub-process scope
export BASE_OUTPUT_DIR STATUS_FILE

# Run the python server in the foreground to keep the container alive and clear background processes cleanly
trap 'echo "Shutting down..."; kill $(jobs -p) 2>/dev/null; exit 0' SIGINT SIGTERM
python3 /tmp/server.py
