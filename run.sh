#!/bin/bash

echo "========================================"
echo "JAKE'S STATION RIPPER STARTING"
echo "BUILD TEST: 2026-10-11-10"
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
MIN_FILE_SIZE_MB="1.0"
STREAM_URLS=()

if [ -f "$CONFIG_PATH" ]; then
    BASE_OUTPUT_DIR=$(jq --raw-output '.output_dir // "/media/stationripper"' "$CONFIG_PATH")
    LOGGING_ENABLED=$(jq --raw-output '.logging // false' "$CONFIG_PATH")
    MIN_FILE_SIZE_MB=$(jq --raw-output '.min_file_size_mb // 1' "$CONFIG_PATH")
    CONTINUOUS_RECORDING=$(jq --raw-output '.continuous_recording // false' "$CONFIG_PATH")
    mapfile -t STREAM_URLS < <(jq --raw-output '.streams[] // empty' "$CONFIG_PATH")
fi

if [ ${#STREAM_URLS[@]} -eq 0 ]; then
    echo "⚠️ No streams configured. The Ingress UI will remain available so you can add one."
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

increment_ads_removed() {
    local count="$1"

    (
        flock 200

        local current
        current=$(jq -r '.count // 0' "$ADS_REMOVED_FILE" 2>/dev/null) || current=0
        [[ "$current" =~ ^[0-9]+$ ]] || current=0
        current=$((current + count))

        local tmp_file="${ADS_REMOVED_FILE}.$$"

        if jq --argjson count "$current" '.count = $count' \
            "$ADS_REMOVED_FILE" > "$tmp_file" 2>/dev/null; then
            mv -f "$tmp_file" "$ADS_REMOVED_FILE"
        else
            rm -f "$tmp_file"
            echo "{\"count\": $current}" > "$ADS_REMOVED_FILE"
        fi
    ) 200>"$ADS_REMOVED_LOCK"
}

# File monitor
watch_all_completed_files() {
    echo "👀 MP3 cleanup started: $BASE_OUTPUT_DIR"

    inotifywait \
        --monitor \
        --quiet \
        --recursive \
        --event close_write \
        --event moved_to \
        --format '%w%f' \
        "$BASE_OUTPUT_DIR" |
    while IFS= read -r REAL_PATH; do

        case "$REAL_PATH" in
            *.mp3|*.MP3) ;;
            *) continue ;;
        esac

        case "$REAL_PATH" in
            */incomplete/*) continue ;;
        esac

        (
            # Allow Streamripper to finish
            sleep 2

            [ -f "$REAL_PATH" ] || exit 0

            FILE_SIZE=$(stat -c%s "$REAL_PATH" 2>/dev/null) || exit 0

            [ "$FILE_SIZE" -gt 0 ] || exit 0
            [ "$FILE_SIZE" -lt "$MIN_FILE_SIZE_BYTES" ] || exit 0

            sleep 3

            [ -f "$REAL_PATH" ] || exit 0

            CURRENT_SIZE=$(stat -c%s "$REAL_PATH" 2>/dev/null) || exit 0

            [ "$CURRENT_SIZE" -eq "$FILE_SIZE" ] || exit 0

            STREAM_SOURCE=$(basename "$(dirname "$REAL_PATH")")

            echo "🧹 [$STREAM_SOURCE] Removing small MP3: $REAL_PATH"

            if rm -f -- "$REAL_PATH" && [ ! -e "$REAL_PATH" ]; then
                increment_ads_removed 1
                echo "🗑️ Removed successfully"
            else
                echo "⚠️ Could not remove: $REAL_PATH"
            fi
        ) &

    done
}

# Start watcher if not in continuous_recording mode
GLOBAL_WATCHER_PID=""
if [ "${CONTINUOUS_RECORDING}" != "true" ]; then
    watch_all_completed_files &
    GLOBAL_WATCHER_PID=$!
fi

STREAM_URLS_JSON=$(printf '%s\n' "${STREAM_URLS[@]}" |
    jq -Rsc 'split("\n") | map(select(length > 0))')
export STREAM_URLS_JSON

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
                    -i
                    --xs-none
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
import html
import threading
import urllib.request
import urllib.error

from urllib.parse import parse_qs, urlparse
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

CONFIG_PATH = "/data/options.json"

SUPERVISOR_URL = "http://supervisor"
ADDON_SLUG = "self"

def supervisor_request(method, endpoint, payload=None):
    """Make an authenticated request to the Supervisor API."""
    token = os.environ.get("SUPERVISOR_TOKEN")

    if not token:
        raise RuntimeError(
            "SUPERVISOR_TOKEN is missing. Check add-on API permissions."
        )

    body = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    if payload is not None:
        body = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(
        f"{SUPERVISOR_URL}{endpoint}",
        data=body,
        headers=headers,
        method=method,
    )

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        details = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"Supervisor HTTP {e.code} for {endpoint}: {details}"
        ) from e
    except urllib.error.URLError as e:
        raise RuntimeError(
            f"Cannot reach Supervisor at {SUPERVISOR_URL}: {e}"
        ) from e

    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        raise RuntimeError(
            f"Supervisor returned non-JSON data for {endpoint}: {raw[:500]}"
        )

    if result.get("result") == "error":
        raise RuntimeError(
            result.get("message", "Supervisor API error")
        )

    if result.get("result") not in (None, "ok"):
        raise RuntimeError(f"Unexpected Supervisor response: {result}")

    return result.get("data", result)

def get_addon_options():
    """Read the authoritative options stored by Home Assistant."""
    data = supervisor_request(
        "GET",
        f"/addons/{ADDON_SLUG}/info",
    )

    options = data.get("options")

    if not isinstance(options, dict):
        raise RuntimeError(
            "Supervisor did not return the add-on options"
        )

    return options


def get_configured_streams():
    """Return the configured stream URLs."""
    options = get_addon_options()
    streams = options.get("streams", [])

    if not isinstance(streams, list):
        return []

    return list(dict.fromkeys(
        url.strip()
        for url in streams
        if isinstance(url, str) and url.strip()
    ))


def load_saved_streams():
    """Build the Saved Streams display from the add-on configuration."""
    streams = []

    for url in get_configured_streams():
        name = urlparse(url).hostname or url

        streams.append({
            "name": name,
            "url": url,
        })

    return streams


def save_configured_streams(stream_urls):
    """Update the add-on options without overwriting other settings."""
    options = get_addon_options()

    # Keep the existing configuration and replace only the stream list.
    options["streams"] = list(dict.fromkeys(
        url.strip()
        for url in stream_urls
        if isinstance(url, str) and url.strip()
    ))

    supervisor_request(
        "POST",
        f"/addons/{ADDON_SLUG}/options",
        {"options": options},
    )


def restart_addon():
    """Restart after the HTTP response has had time to return."""
    def restart_worker():
        time.sleep(2)

        try:
            supervisor_request(
                "POST",
                f"/addons/{ADDON_SLUG}/restart",
            )
            print("🔄 Add-on restart requested successfully")

        except Exception as e:
            print(f"⚠️ Could not restart add-on: {e}")

    threading.Thread(
        target=restart_worker,
        daemon=True,
    ).start()
    
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

        saved_stream_rows = ""

        try:
            configured_streams = load_saved_streams()
        except Exception as e:
            print(f"⚠️ Could not load configured streams: {e}")
            configured_streams = []

        for stream in configured_streams:
            if not isinstance(stream, dict):
                continue

            name = html.escape(str(stream.get("name", "")))
            url = str(stream.get("url", ""))
            safe_url = html.escape(url)
            safe_url_attr = html.escape(url, quote=True)

            saved_stream_rows += f"""
            <li>
                <div style="display:flex;flex-direction:column;width:100%;">
                    <strong>{name}</strong>
                    <small style="margin-top:3px;overflow-wrap:anywhere;white-space:normal;">
                        {safe_url}
                    </small>
                    <form method="POST" style="margin-top:8px;">
                        <input type="hidden" name="action" value="remove_stream">
                        <input type="hidden" name="url" value="{safe_url_attr}">
                        <button type="submit" style="background:#d32f2f;">
                            Remove Stream
                        </button>
                    </form>
                </div>
            </li>
            """

        if not saved_stream_rows:
            saved_stream_rows = "<li>No saved streams yet</li>"
            
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
        <h2>📚 Saved Streams</h2>

        <p style="color:#aaa;">
            Your previously configured radio stations are remembered here.
        </p>

        <form method="POST" class="form-container">
            <input type="hidden" name="action" value="save_stream">

            <label for="stream-name">Station Name</label>
            <input id="stream-name" name="name"
                   type="text" required
                   placeholder="My Favorite Radio Station"
                   style="width:100%;box-sizing:border-box;padding:12px;
                          margin:8px 0 16px;background:#191919;
                          color:#fff;border:1px solid #444;border-radius:4px;">

            <label for="stream-url">Stream URL</label>
            <input id="stream-url" name="url"
                   type="url" required
                   placeholder="https://example.com/radio"
                   style="width:100%;box-sizing:border-box;padding:12px;
                          margin:8px 0 16px;background:#191919;
                          color:#fff;border:1px solid #444;border-radius:4px;">

            <button type="submit" style="background:#4caf50;">
                ➕ Save Stream
            </button>
        </form>

        <ul>{saved_stream_rows}</ul>
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
            content_length = int(
                self.headers.get("Content-Length", 0)
            )

            body = self.rfile.read(content_length).decode("utf-8")
            form = parse_qs(body)

            action = form.get("action", ["purge_duplicates"])[0]

            if action in ("save_stream", "remove_stream"):
                urls = get_configured_streams()
                changed = False

                if action == "save_stream":
                    url = form.get("url", [""])[0].strip()

                    if not url:
                        raise ValueError("Stream URL is required")

                    parsed = urlparse(url)

                    if parsed.scheme not in ("http", "https") or not parsed.netloc:
                        raise ValueError(
                            "Enter a valid HTTP or HTTPS stream URL"
                        )

                    if url not in urls:
                        urls.append(url)
                        save_configured_streams(urls)
                        changed = True
                        print(f"📚 Added configured stream: {url}")
                    else:
                        print(f"ℹ️ Stream already configured: {url}")

                elif action == "remove_stream":
                    url = form.get("url", [""])[0].strip()

                    if url in urls:
                        urls = [item for item in urls if item != url]
                        save_configured_streams(urls)
                        changed = True
                        print(f"🗑️ Removed configured stream: {url}")

                self.send_response(303)
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.end_headers()

                if changed:
                    restart_addon()

                return
                
            elif action == "purge_duplicates":
                subprocess.run(
                    [
                        "bash", "-c",
                        """
                        find "$1" -type f -name '*.mp3' \
                            -regextype posix-extended \
                            -regex '.*\\([0-9]+\\)\\.mp3' \
                            -delete
                        """,
                        "purge",
                        BASE_OUTPUT_DIR
                    ],
                    check=False
                )

            self.send_response(303)
            self.send_header("Location", "/")
            self.send_header("Content-Length", "0")
            self.end_headers()

        except Exception as e:
            import traceback

            error_text = f"{type(e).__name__}: {e}"
            print(f"❌ Web action failed: {error_text}", flush=True)
            traceback.print_exc()

            message = (
                "Could not update stream configuration.\n\n"
                f"Error: {error_text}\n\n"
                "Check the add-on logs for the full traceback."
            ).encode("utf-8")

            try:
                self.send_response(500)
                self.send_header(
                    "Content-Type",
                    "text/plain; charset=UTF-8",
                )
                self.send_header("Content-Length", str(len(message)))
                self.end_headers()
                self.wfile.write(message)
            except Exception:
                pass

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

    if [ -n "${GLOBAL_WATCHER_PID:-}" ]; then
        kill "$GLOBAL_WATCHER_PID" 2>/dev/null || true
    fi

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
