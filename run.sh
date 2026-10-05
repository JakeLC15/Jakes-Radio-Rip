#!/bin/bash

echo "========================================"
echo "JAKE'S STATION RIPPER STARTING"
echo "BUILD TEST: 2026-10-05-2"
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
START_TIME=$(date +%s)

echo "{}" > "$STATUS_FILE"

# --- CLEAN OLD INCOMPLETE FILES AT STARTUP ---
echo "🧹 Cleaning old incomplete files..."
rm -f "${BASE_OUTPUT_DIR}"/*/incomplete/* 2>/dev/null

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

# --- NEW: TRACK BACKGROUND PROCESSES ---
RIPPER_PIDS=()
PYTHON_PID=""

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

    # NEW: Save the background wrapper PID
    RIPPER_PIDS+=("$!")
done

# --- PYTHON-BASED MULTI-THREADED INGRESS ENGINE ---
echo "🚀 Starting Ingress Web UI engine on port 8099..."

cat << 'EOF' > /tmp/server.py
import os
import subprocess
import json
import time
import shutil
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

BASE_OUTPUT_DIR = os.environ.get("BASE_OUTPUT_DIR", "/media/stationripper")
STATUS_FILE = os.environ.get("STATUS_FILE", f"{BASE_OUTPUT_DIR}/status.json")
START_TIME = int(os.environ.get("START_TIME", time.time()))

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

class IngressHandler(BaseHTTPRequestHandler):
    def _get_files(self):
        files = []
        today = datetime.now().date()
        today_count = 0

        for root, dirs, names in os.walk(BASE_OUTPUT_DIR):
            for name in names:
                if not name.lower().endswith(".mp3"):
                    continue

                path = os.path.join(root, name)

                try:
                    mtime = os.path.getmtime(path)
                    files.append((mtime, path))

                    if datetime.fromtimestamp(mtime).date() == today:
                        today_count += 1
                except:
                    pass

        files.sort(reverse=True)
        return files, today_count

    def _format_size(self, size):
        for unit in ["B", "KB", "MB", "GB", "TB"]:
            if size < 1024:
                return f"{size:.1f} {unit}"
            size /= 1024
        return f"{size:.1f} PB"

    def _format_uptime(self):
        seconds = max(0, int(time.time()) - START_TIME)
        days, seconds = divmod(seconds, 86400)
        hours, seconds = divmod(seconds, 3600)
        minutes, seconds = divmod(seconds, 60)

        if days:
            return f"{days}d {hours}h {minutes}m"
        if hours:
            return f"{hours}h {minutes}m"
        return f"{minutes}m {seconds}s"

    def _render_page(self):
        files, today_count = self._get_files()

        current_count = len(files)

        try:
            usage = shutil.disk_usage(BASE_OUTPUT_DIR)
            disk_used = self._format_size(usage.used)
            disk_free = self._format_size(usage.free)
            disk_total = self._format_size(usage.total)
            disk_percent = (usage.used / usage.total) * 100
        except:
            disk_used = disk_free = disk_total = "Unknown"
            disk_percent = 0

        station_rows = ""
        reconnect_rows = ""

        if os.path.exists(STATUS_FILE):
            try:
                with open(STATUS_FILE, 'r') as f:
                    data = json.load(f)

                for station, status in data.items():
                    if isinstance(status, dict):
                        state = status.get("status", "Unknown")
                        reconnects = status.get("reconnects", 0)
                        last_error = status.get("last_error", "")
                    else:
                        state = status
                        reconnects = 0
                        last_error = ""

                    if state == "Ripping":
                        indicator = "🟢"
                    else:
                        indicator = "🔴"

                    station_rows += f"""
                    <li>
                        <span>{indicator} <strong>{station}</strong></span>
                        <span>{state}</span>
                    </li>
                    """

                    reconnect_text = f"{reconnects} reconnects"
                    if last_error:
                        reconnect_text += f" — {last_error}"

                    reconnect_rows += f"""
                    <li>
                        <span><strong>{station}</strong></span>
                        <span>{reconnect_text}</span>
                    </li>
                    """
            except:
                pass

        if not station_rows:
            station_rows = "<li>No active streams found</li>"

        if not reconnect_rows:
            reconnect_rows = "<li>No stream information available</li>"

        current_song = "No tracks yet"

        if files:
            current_song = os.path.basename(files[0][1])
            current_song = os.path.splitext(current_song)[0]

        recent_rows = ""

        for mtime, path in files[:10]:
            name = os.path.splitext(os.path.basename(path))[0]
            station = os.path.basename(os.path.dirname(path))
            when = datetime.fromtimestamp(mtime).strftime("%H:%M:%S")

            recent_rows += f"""
            <li>
                <span>{name}</span>
                <small>{station} · {when}</small>
            </li>
            """

        if not recent_rows:
            recent_rows = "<li>No tracks yet</li>"

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
    <meta http-equiv="refresh" content="10">
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #111; color: #eee; padding: 20px; }}
        .card {{ background: #222; padding: 20px; border-radius: 8px; max-width: 650px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }}
        h2 {{ margin-top: 0; color: #03a9f4; }}
        ul {{ list-style: none; padding: 0; margin-bottom: 0; }}
        li {{ padding: 10px 0; border-bottom: 1px solid #333; display: flex; justify-content: space-between; gap: 15px; }}
        li:last-child {{ border-bottom: none; }}
        button {{ display: block; text-align: center; color: white; border: none; padding: 12px 20px; font-weight: bold; border-radius: 4px; cursor: pointer; width: 100%; font-size: 14px; margin-bottom: 16px; box-sizing: border-box; }}
        .btn-refresh {{ background: #03a9f4; }}
        .btn-refresh:hover {{ background: #0288d1; }}
        .btn-media {{ background: #4caf50; }}
        .btn-media:hover {{ background: #43a047; }}
        .btn-purge {{ background: #ff9800; margin-bottom: 0; }}
        .btn-purge:hover {{ background: #e68a00; }}
        .count {{ font-size: 24px; font-weight: bold; color: #4caf50; margin: 10px 0 20px 0; }}
        .current {{ font-size: 20px; font-weight: bold; color: #fff; margin: 10px 0 20px 0; word-break: break-word; }}
        .stats {{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }}
        .stat {{ background: #191919; padding: 14px; border-radius: 6px; }}
        .stat-value {{ font-size: 20px; font-weight: bold; margin-top: 5px; }}
        small {{ color: #999; white-space: nowrap; }}
        .form-container {{ display: block; margin-top: 16px; }}
    </style>
</head>
<body>

    <div class="card">
        <h2>📻 Live Stream Status</h2>
        <ul>{station_rows}</ul>
    </div>

    <div class="card">
        <h2>🎵 Current Track</h2>
        <div class="current">{current_song}</div>
    </div>

    <div class="card">
        <h2>📊 Library</h2>

        <div class="stats">
            <div class="stat">
                Total Tracks
                <div class="stat-value">{current_count}</div>
            </div>

            <div class="stat">
                Tracks Today
                <div class="stat-value">{today_count}</div>
            </div>

            <div class="stat">
                Disk Used
                <div class="stat-value">{disk_used}</div>
            </div>

            <div class="stat">
                Disk Free
                <div class="stat-value">{disk_free}</div>
            </div>

            <div class="stat">
                Disk Total
                <div class="stat-value">{disk_total}</div>
            </div>

            <div class="stat">
                Disk Usage
                <div class="stat-value">{disk_percent:.1f}%</div>
            </div>

            <div class="stat">
                Uptime
                <div class="stat-value">{self._format_uptime()}</div>
            </div>
        </div>
    </div>

    <div class="card">
        <h2>🔄 Connection History</h2>
        <ul>{reconnect_rows}</ul>
    </div>

    <div class="card">
        <h2>🕘 Recent Tracks</h2>
        <ul>{recent_rows}</ul>
    </div>

    <div class="card">
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

        self.wfile.write(self._render_page().encode('utf-8'))

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=UTF-8')
        self.end_headers()

        self.wfile.write(self._render_page().encode('utf-8'))

if __name__ == '__main__':
    server = ThreadedHTTPServer(('0.0.0.0', 8099), IngressHandler)
    server.serve_forever()
EOF

# Export environment paths to python sub-process scope
export BASE_OUTPUT_DIR STATUS_FILE START_TIME

# --- CHANGED: CLEAN SHUTDOWN ---
shutdown_handler() {
    echo "Shutting down Jakes Station Ripper..."

    # Stop Python server
    if [ -n "$PYTHON_PID" ]; then
        kill "$PYTHON_PID" 2>/dev/null || true
    fi

    # Stop all ripper wrapper processes
    for PID in "${RIPPER_PIDS[@]}"; do
        kill "$PID" 2>/dev/null || true
    done

    # Give children a moment to exit
    sleep 1

    # Force anything still running
    if [ -n "$PYTHON_PID" ]; then
        kill -9 "$PYTHON_PID" 2>/dev/null || true
    fi

    for PID in "${RIPPER_PIDS[@]}"; do
        kill -9 "$PID" 2>/dev/null || true
    done

    echo "Done. Safe exit."
    exit 0
}

# Register shutdown
trap 'shutdown_handler' SIGINT SIGTERM

# Run the python server in the foreground to keep the container alive
python3 /tmp/server.py &

# NEW: Save Python PID
PYTHON_PID=$!

# Wait for Python server
wait "$PYTHON_PID"
