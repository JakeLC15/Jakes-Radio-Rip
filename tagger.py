import sys
import time
import os
import fcntl
import musicbrainzngs
from mutagen.easyid3 import EasyID3

# Register key targets into EasyID3's namespace cleanly
EasyID3.RegisterKey('musicbrainz_recordingid', EasyID3.GetTXXXKey('MusicBrainz Recording Id'))
EasyID3.RegisterKey('musicbrainz_artistid', EasyID3.GetTXXXKey('MusicBrainz Artist Id'))

musicbrainzngs.set_useragent("JakesRadioRipCustomTagger", "1.0", "ha-addon-user@example.com")

def clean_and_tag_file(file_path, raw_title):
    if not os.path.exists(file_path):
        print(f"File not found yet: {file_path}")
        return

    # Clear trailing duplicate digits appended by stream managers
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
        
        # Enforce API connection concurrency safety rules
        time.sleep(2.0)

        try:
            print(f"Querying MusicBrainz for: {artist.strip()} - {title.strip()}")
            result = musicbrainzngs.search_recordings(artist=artist.strip(), recording=title.strip(), limit=1)
            
            if result.get('recording-list'):
                match = result['recording-list'][0]
                
                clean_title = match.get('title', title.strip())
                
                # Parse the nested artist payload structure safely
                credits_list = match.get('artist-credit', [{}])
                if credits_list and isinstance(credits_list, list):
                    clean_artist = credits_list[0].get('artist', {}).get('name', artist.strip())
                else:
                    clean_artist = artist.strip()
                
                # FIX: Access the first element index [0] inside the release-list array
                album_name = "Radio Rip"
                release_list = match.get('release-list', [])
                if release_list and isinstance(release_list, list) and len(release_list) > 0:
                    album_name = release_list[0].get('title', "Radio Rip")
                
                # Open audio layout profile to commit the elements to disk
                audio = EasyID3(file_path)
                audio['title'] = clean_title
                audio['artist'] = clean_artist
                audio['album'] = album_name
                audio['musicbrainz_recordingid'] = match['id']
                audio.save()
                print(f"Successfully tagged: {clean_artist} - {clean_title} [Album: {album_name}]")
            else:
                print(f"No match found for: {raw_title}")
                
        except Exception as e:
            print(f"Metadata processing failure: {e}")

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        clean_and_tag_file(sys.argv[1], sys.argv[2])
