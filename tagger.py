import sys
import time
import os
import musicbrainzngs
from mutagen.easyid3 import EasyID3

# MusicBrainz strictly requires a uniquely descriptive user-agent string
musicbrainzngs.set_useragent("JakesRadioRipCustomTagger", "1.0", "ha-addon-user@example.com")

def clean_and_tag_file(file_path, raw_title):
    if not os.path.exists(file_path):
        print(f"Error: File targets do not exist at {file_path}")
        return

    # Fallback to file parsing if separation characters are complex
    artist, title = "", ""
    if " - " in raw_title:
        artist, title = raw_title.split(" - ", 1)
    else:
        print(f"Skipping lookup: Metadata layout '{raw_title}' cannot be reliably split.")
        return

    # Safety throttle: prevents instant global bans when multiple stations finish tracks concurrently
    time.sleep(1.2)

    try:
        print(f"Querying MusicBrainz for: Artist='{artist}', Title='{title}'")
        result = musicbrainzngs.search_recordings(artist=artist, recording=title, limit=1)
        
        if result.get('recording-list'):
            match = result['recording-list'][0]
            
            clean_title = match.get('title', title)
            clean_artist = match.get('artist-credit', [{}])[0].get('artist', {}).get('name', artist)
            
            # Look for an available release album name
            album_name = "Radio Rip"
            if match.get('release-list'):
                album_name = match['release-list'][0].get('title', "Radio Rip")
            
            # Map tracking data directly into ID3 containers
            audio = EasyID3(file_path)
            audio['title'] = clean_title
            audio['artist'] = clean_artist
            audio['album'] = album_name
            # Crucial: Home Assistant's Music Assistant relies on this ID to tie tracks together
            audio['musicbrainz_recordingid'] = match['id'] 
            audio.save()
            print(f"Successfully tagged track: {clean_artist} - {clean_title} [Album: {album_name}]")
        else:
            print("No authoritative matches found on MusicBrainz. Keeping original stream metadata.")
            
    except Exception as e:
        print(f"Metadata processing failure: {e}")

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        clean_and_tag_file(sys.argv[1], sys.argv[2])
