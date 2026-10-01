#!/bin/bash
set -e

CONFIG_PATH="/data/options.json"
OUTPUT_DIR="/media/DATA2/Music/jakes_station_rip"

# 1. Read the stream URL from the Home Assistant add-on options
if [ -f "$CONFIG_PATH" ]; then
    STREAM_URL=$(jq --raw-output '.stream_url // empty' "$CONFIG_PATH")
fi

# 2. Safety check: make sure the user actually provided a URL
if [ -z "$STREAM_URL" ]; then
    echo "❌ Error: No 'stream_url' found in your add-on configuration!"
    exit 1
fi

# 3. Create the output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

echo "🎵 Connecting to: $STREAM_URL"
echo "📂 Saving tracks directly to: $OUTPUT_DIR"

# 4. Run streamripper (Removed the invalid --codeset option)
# -a rips everything into individual tracks natively
exec streamripper "$STREAM_URL" -d "$OUTPUT_DIR" -a
