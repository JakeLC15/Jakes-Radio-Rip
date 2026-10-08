#!/bin/bash

echo "========================================"
echo "JAKE'S STATION RIPPER STARTING"
echo "BUILD TEST: 2026-10-08-2"
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
CONTINUOUS_RECORDING="false"

if [ -f "$CONFIG_PATH" ]; then
    BASE_OUTPUT_DIR=$(jq --raw-output '.output_dir // "/media/stationripper"' "$CONFIG_PATH")
    LOGGING_ENABLED=$(jq --raw-output '.logging // false' "$CONFIG_PATH")
    MIN_FILE_SIZE_MB=$(jq --raw-output '.min_file_size_mb // 1' "$CONFIG_PATH")
    CONTINUOUS_RECORDING=$(jq --raw-output '.continuous_recording // false' "$CONFIG_PATH")
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
#MIN_FILE_SIZE_BYTES=$(awk "BEGIN {printf \"%d\", $MIN_FILE_SIZE_MB * 1024 * 1024}")
MIN_FILE_SIZE_BYTES=$(awk -v mb="$MIN_FILE_SIZE_MB" \
    'BEGIN { printf "%.0f", mb * 1024 * 1024 }')
    
echo "Minimum retained MP3 size: ${MIN_FILE_SIZE_MB} MB"
echo "{}" > "$STATUS_FILE"

ADS_REMOVED_FILE="${BASE_OUTPUT_DIR}/ads_removed.json"
ADS_REMOVED_LOCK="${BASE_OUTPUT_DIR}/ads_removed.lock"

export ADS_REMOVED_FILE
export ADS_REMOVED_LOCK

if [ ! -f "$ADS_REMOVED_FILE" ]; then
    echo '{"count":0}' > "$ADS_REMOVED_FILE"
fi

# Clean up incomplete
echo "🧹 Cleaning old incomplete files..."
find "$BASE_OUTPUT_DIR" -type f -path "*/incomplete/*" -delete 2>/dev/null

# Status function
update_status() {
    local station="$1"
    local status="$2"
    local reconnects="${3:-0}"
    local error="${4:-}"
    (
        flock 200
        TMP_FILE="${STATUS_FILE}.$$"
        if jq \
            --arg station "$station" \
            --arg status "$status" \
            --argjson reconnects "$reconnects" \
            --arg error "$error" \
            '. + {($station): {status: $status, reconnects: $reconnects, last_error: $error}}' \
            "$STATUS_FILE" > "$TMP_FILE"; then
            mv "$TMP_FILE" "$STATUS_FILE"
        else
            rm -f "$TMP_FILE"
            echo "⚠️ Failed to update status for $station"
        fi
    ) 200>"$STATUS_LOCK"
}

# Purge button function
run_duplicate_cleanup() {
    echo "🧹 Starting manual duplicate purge..."
    find "$BASE_OUTPUT_DIR" -type f -name "*.mp3" | grep -E "\([0-9]+\)\.mp3$" | tr '\n' '\0' | xargs -0 rm -f
    echo "✅ Duplicate purge complete!"
}

# Files removed less than spec function
increment_ads_removed() {
    local count="$1"
    [ -n "${ADS_REMOVED_FILE:-}" ] || return 0

    (
        flock 200

        # Read current count safely via piping to prevent file handle lockouts
        local current
        current=$(cat "$ADS_REMOVED_FILE" 2>/dev/null | jq -r '.count // 0' || echo 0)
        [ -z "$current" ] && current=0

        current=$((current + count))
        local tmp_file="${ADS_REMOVED_FILE}.$$"

        # Update JSON safely
        if jq --argjson count "$current" '.count = $count' "$ADS_REMOVED_FILE" > "$tmp_file" 2>/dev/null; then
            mv -f "$tmp_file" "$ADS_REMOVED_FILE"
        else
            rm -f "$tmp_file"
            # Fallback direct generation if file gets corrupted or unreadable
            echo "{\"count\": $current}" > "$ADS_REMOVED_FILE"
        fi
    ) 200>"$ADS_REMOVED_LOCK"
}

# Watch for completed MP3 files without repeatedly scanning directories
watch_completed_files() {
    echo "👀 Watching $STREAM_DIR (and subfolders) for completed MP3 files..."

    declare -A PROCESSED_FILES
    declare -a PROCESS_HISTORY
    local MAX_HISTORY=50

    exec 3< <(
        inotifywait \
            --monitor \
            --quiet \
            --recursive \
            --event close_write \
            --event moved_to \
            --format '%e|%w%f%0' \
            "$STREAM_DIR"
    )

    while IFS='|' read -u 3 -r -d '' EVENT FILE; do

        # 1. Standard extension filters
        case "$FILE" in
            *.mp3|*.MP3) ;;
            *) continue ;;
        esac

        case "$FILE" in
            */incomplete/*) continue ;;
        esac

        # 2. IMMEDIATE LOCK PROTECTION (Drops the 5 duplicate stream events instantly)
        if [ "${PROCESSED_FILES["$FILE"]:-0}" = "1" ]; then
            continue
        fi
        PROCESSED_FILES["$FILE"]=1
        
        # 3. GARBAGE COLLECTION (Prevents 5 multi-streams from leaking RAM)
        PROCESS_HISTORY+=("$FILE")
        if [ "${#PROCESS_HISTORY[@]}" -gt "$MAX_HISTORY" ]; then
            local OLDEST_FILE="${PROCESS_HISTORY[0]}"
            unset 'PROCESSED_FILES["$OLDEST_FILE"]'   # Evict oldest entry from tracking
            PROCESS_HISTORY=("${PROCESS_HISTORY[@]:1}") # Pop from array index
        fi

        # 4. Settle delay to let Streamripper clear OS file locks
        sleep 0.3

        [ -f "$FILE" ] || continue
        FILE_SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo 0)

        # 5. Advanced Evaluation and Deletion
        if [ "$FILE_SIZE" -lt "$MIN_FILE_SIZE_BYTES" ]; then
            FILE_NAME=$(basename "$FILE")
            # Extract parent folder name to log WHICH stream produced the file
            STREAM_SOURCE=$(basename "$(dirname "$FILE")")

            echo "🧹 [$STREAM_SOURCE] Removing small MP3: $FILE_NAME (${FILE_SIZE} bytes)"

            # Drop file and handle parallel OS read locks safely
            if rm -- "$FILE" 2>/dev/null; then
                increment_ads_removed 1
                echo "🗑️ Removed successfully"
            else
                sleep 0.5
                if rm -f -- "$FILE"; then
                    increment_ads_removed 1
                    echo "🗑️ Forced removal successful after cool-down"
                else
                    echo "❌ ERROR: System locked path: $FILE_NAME"
                fi
            fi
        fi

    done

    exec 3<&-
}

# Track Background
RIPPER_PIDS=()
PYTHON_PID=""

# Background rip threads
for URL in "${STREAM_URLS[@]}"; do
    FOLDER_NAME=$(echo "$URL" | awk -F/ '{print $3}')
    [ -z "$FOLDER_NAME" ] && FOLDER_NAME="stream"
    STREAM_DIR="${BASE_OUTPUT_DIR}/${FOLDER_NAME}"

    (
        RECONNECTS=0
    
        for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
            echo "Starting Streamripper for $FOLDER_NAME..."
            mkdir -p "$STREAM_DIR"
            update_status "$FOLDER_NAME" "Ripping" "$RECONNECTS" ""

            if [ "${CONTINUOUS_RECORDING}" = "true" ]; then
                echo "📻 Continuous recording enabled for $FOLDER_NAME"
            
                RIPPER_ARGS=(
                    "$URL"
                    -d "$STREAM_DIR"
                    -a "continuous.mp3"
                    -A
                    -u "WinampMPEG/5.0"
                    --no-cue
                )
            else
                RIPPER_ARGS=(
                    "$URL"
                    -d "$STREAM_DIR"
                    -u "WinampMPEG/5.0"
                    --no-cue
                )
            fi
            
            if [ "${LOGGING_ENABLED}" != "true" ]; then
                RIPPER_ARGS+=(--quiet)
            fi

           CLEANUP_PID=""

            if [ "${CONTINUOUS_RECORDING}" != "true" ]; then
                watch_completed_files &
                CLEANUP_PID=$!
            fi
            
            streamripper "${RIPPER_ARGS[@]}"
            
            RC=$?
            
            # Stop the file watcher after Streamripper exits
            if [ -n "$CLEANUP_PID" ]; then
                kill "$CLEANUP_PID" 2>/dev/null || true
                wait "$CLEANUP_PID" 2>/dev/null || true
            fi

            [ "$RC" -eq 0 ] && {
                update_status "$FOLDER_NAME" "Offline" "$RECONNECTS" ""
                break
            }

            RECONNECTS=$((RECONNECTS + 1))
            update_status "$FOLDER_NAME" "Offline" "$RECONNECTS" "Streamripper exited with code $RC"

            sleep "$RETRY_DELAY"
        done

    ) &

    # Save the background wrapper PID
    RIPPER_PIDS+=("$!")
done

# Python Ingress - Web UI
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
ADS_REMOVED_FILE = os.environ.get(
    "ADS_REMOVED_FILE",
    f"{BASE_OUTPUT_DIR}/ads_removed.json"
)

MIN_FILE_SIZE_MB = float(os.environ.get("MIN_FILE_SIZE_MB", "1"))

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

class IngressHandler(BaseHTTPRequestHandler):
    def _get_files(self):
        files = []
        today = datetime.now().date()
        today_count = 0

        for root, dirs, names in os.walk(BASE_OUTPUT_DIR):
            dirs[:] = [d for d in dirs if d.lower() != "incomplete"]
        
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

    def _get_ads_removed(self):
        try:
            with open(ADS_REMOVED_FILE, "r") as f:
                data = json.load(f)
                return int(data.get("count", 0))
        except:
            return 0

    def _render_page(self):
        files, today_count = self._get_files()

        current_count = len(files)
        ads_removed = self._get_ads_removed()

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
                        <div style="display: flex; flex-direction: column; width: 100%;">
                            <span style="font-weight: bold; color: #fff;">{station}</span>
                            <small style="color: #999; margin-top: 3px;">{reconnect_text}</small>
                        </div>
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
                        <div style="display: flex; flex-direction: column; width: 100%;">
                            <span style="font-weight: 500; color: #fff; word-break: break-all;">{name}</span>
                            <small style="color: #999; margin-top: 3px;">📁 {station} · ⏱️ {when}</small>
                        </div>
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
<html style="background-color: #111;">
<head>
    <title>Jake's Station Ripper</title>
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
        <ul id="station-list">{station_rows}</ul>
    </div>

    <div class="card">
        <h2>🎵 Current Track</h2>
        <div class="current" id="current-song">{current_song}</div>
    </div>

    <div class="card">
        <h2>📊 Library</h2>

        <div class="stats">
            <div class="stat">
                Total Tracks
                <div class="stat-value" id="stat-total">{current_count}</div>
            </div>

            <div class="stat">
                Tracks Today
                <div class="stat-value" id="stat-today">{today_count}</div>
            </div>

            <div class="stat">
                Ads Removed
                <div class="stat-value" id="stat-ads-removed">{ads_removed}</div>
                <small>Files smaller than {MIN_FILE_SIZE_MB} MB</small>
            </div>
            
            <div class="stat">
                Disk Used
                <div class="stat-value" id="stat-used">{disk_used}</div>
            </div>

            <div class="stat">
                Disk Free
                <div class="stat-value" id="stat-free">{disk_free}</div>
            </div>

            <div class="stat">
                Disk Total
                <div class="stat-value" id="stat-total-disk">{disk_total}</div>
            </div>

            <div class="stat">
                Disk Usage
                <div class="stat-value" id="stat-percent">{disk_percent:.1f}%</div>
            </div>

            <div class="stat">
                Uptime
                <div class="stat-value" id="stat-uptime">{self._format_uptime()}</div>
            </div>
        </div>
    </div>

    <div class="card">
        <h2>🔄 Connection History</h2>
        <ul id="reconnect-list">{reconnect_rows}</ul>
    </div>

    <div class="card">
        <h2>🕘 Recent Tracks</h2>
        <ul id="recent-list">{recent_rows}</ul>
    </div>

    <div class="card">
        <button class="btn-refresh" onclick="window.location.reload();">🔄 Refresh Live Data</button>

        <button class="btn-media" onclick="window.parent.history.pushState(null, '', '{target_media_url}'); window.parent.dispatchEvent(new PopStateEvent('popstate'));">📁 Open Media Browser</button>

        <form method="POST" class="form-container">
            <button type="submit" class="btn-purge">🧹 Purge Numbered Duplicates</button>
        </form>
    </div>

    <script>
        setInterval(async () => {{
            try {{
                const res = await fetch(window.location.href);
                const text = await res.text();
                
                // Parse the incoming text cleanly into a hidden document framework
                const parser = new DOMParser();
                const doc = parser.parseFromString(text, 'text/html');

                const elementsToUpdate = [
                    'station-list', 'current-song', 'stat-total', 'stat-today', 
                    'stat-used', 'stat-free', 'stat-total-disk', 'stat-percent',
                    'stat-ads-removed',
                    'stat-uptime', 'reconnect-list', 'recent-list'
                ];

                // Swap out the full contents exactly as they appear on the server
                elementsToUpdate.forEach(id => {{
                    const newEl = doc.getElementById(id);
                    const oldEl = document.getElementById(id);
                    if (newEl && oldEl) {{
                        oldEl.innerHTML = newEl.innerHTML;
                    }}
                }});
            }} catch (e) {{
                console.log("Silent sync background check skipped:", e);
            }}
        }}, 10000);
    </script>
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
export BASE_OUTPUT_DIR STATUS_FILE START_TIME ADS_REMOVED_FILE MIN_FILE_SIZE_MB

# Shutdown function
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

    # Give a sec to exit but not take 10 and trip supervisor
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

# Save Python PID
PYTHON_PID=$!

# Wait for Python server
wait "$PYTHON_PID"
