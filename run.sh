#!/bin/bash
set -e

CONFIG_PATH="/data/options.json"

# 1. Read the base configuration options
if [ -f "$CONFIG_PATH" ]; then
    OUTPUT_DIR=$(jq --raw-output '.output_dir // "/media/stationripper"' "$CONFIG_PATH")
    # Read the streams list into a bash array
    mapfile -t STREAM_URLS < <(jq --raw-output '.streams[] // empty' "$CONFIG_PATH")
fi

# 2. Safety checks
if [ ${#STREAM_URLS[@]} -eq 0 ]; then
    echo "❌ Error: No URLs found in your 'streams' configuration list!"
    exit 1
fi

if [ -z "$OUTPUT_DIR" ]; then
    echo "❌ Error: Output directory is not set!"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "📂 Saving tracks directly to: $OUTPUT_DIR"

# 3. Loop through every URL and spawn a separate streamripper instance in the background
for URL in "${STREAM_URLS[@]}"; do
    echo "🎵 Starting recorder background process for: $URL"
    
    # We remove 'exec' so the script doesn't stop at the first item.
    # The trailing '&' sends each streamripper task to run in the background.
    streamripper "$URL" -d "$OUTPUT_DIR" -a &
done

# 4. Keep the main container alive so Home Assistant knows it is running
# This waits on all background streams to finish. If they all die, the addon stops.
wait

