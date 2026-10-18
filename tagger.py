import sys
import time
import os
import fcntl
import musicbrainzngs
from mutagen.easyid3 import EasyID3

# FIX: Use EasyID3's correct method (RegisterKey) to add tracking keys
EasyID3.RegisterKey('musicbrainz_recordingid', EasyID3.GetTXXXKey('MusicBrainz Recording Id'))
EasyID3.RegisterKey('musicbrainz_artistid', EasyID3.GetTXXXKey('MusicBrainz Artist Id'))

musicbrainzngs.set_useragent("JakesRadioRipCustomTagger", "1.0", "ha-addon-user@example.com")

def clean_and_tag_file(file_path, raw_title):
    if not os.path.exists(file_path):
        print(f"File not found yet: {file_path}")
        return

    # Clean up stream duplicate suffixes like "(1)" from title evaluation string
    title_clean = raw_title
    if title_clean.endswith(' (1)'):
        title_clean = title_clean[:-4]

    if " - " in title_clean:
        artist, title = title_clean.split(" - ", 1)
    else:
        return

    lock_file_path = "/tmp/musicbrainz_api.lock"
    if not os.path.exists(lock_file_path):
        try:
            with open(lock_file_path, "w") as f:
                f.write("")
        except Exception:
            pass

    with open(lock_file_path, "w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX) 
        
        # Mandatory MusicBrainz 1-request-per-second concurrency delay block
        time.sleep(2.0)

        try:
            print(f"Querying MusicBrainz for: {artist.strip()} - {title.strip()}")
            result = musicbrainzngs.search_recordings(artist=artist.strip(), recording=title.strip(), limit=1)
            
            if result.get('recording-list'):
                match = result['recording-list'][0]
                
                clean_title = match.get('title', title.strip())
                
                # FIX: Access the first item in the list before trying to fetch nested dictionary values
                credits_list = match.get('artist-credit', [{}])
                if credits_list and isinstance(credits_list, list):
                    clean_artist = credits_list[0].get('artist', {}).get('name', artist.strip())
                else:
                    clean_artist = artist.strip()
                
                album_name = "Radio Rip"
                if match.get('release-list'):
                    album_name = match['release-list'][0].get('title', "Radio Rip")
                
                # Write tags cleanly to the audio profile destination metadata blocks
                audio = EasyID3(file_path)
                audio['title'] = clean_title
                audio['artist'] = clean_artist
                audio['album'] = album_name
                audio['musicbrainz_recordingid'] = match['id']
                audio.save()
                print(f"Successfully tagged: {clean_artist} - {clean_title}")
            else:
                print(f"No match found for: {raw_title}")
                
        except Exception as e:
            print(f"Metadata processing failure: {e}")

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        clean_and_tag_file(sys.argv[1], sys.argv[2])
