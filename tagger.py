import sys
import time
import os
import fcntl
import musicbrainzngs
from mutagen.easyid3 import EasyID3
from mutagen.id3 import UFID  # Required for proper custom frame mapping

# Register the missing MusicBrainz keys into EasyID3's internal whitelist
EasyID3.RegisterTagger('musicbrainz_recordingid', lambda a, k, v: a.add(UFID(owner="http://musicbrainz.org", data=v[0].encode('utf-8'))))
# Optional extra fields often checked by Home Assistant/Music Assistant:
EasyID3.RegisterTagger('musicbrainz_artistid', lambda a, k, v: a.add(UFID(owner="http://musicbrainz.org", data=v[0].encode('utf-8'))))

musicbrainzngs.set_useragent("JakesRadioRipCustomTagger", "1.0", "ha-addon-user@example.com")

def clean_and_tag_file(file_path, raw_title):
    if not os.path.exists(file_path):
        print(f"File not found yet: {file_path}")
        return

    if " - " in raw_title:
        artist, title = raw_title.split(" - ", 1)
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
        
        # Respect MusicBrainz 1 request per second rule
        time.sleep(2.0)

        try:
            print(f"Querying MusicBrainz for: {artist} - {title}")
            result = musicbrainzngs.search_recordings(artist=artist, recording=title, limit=1)
            
            if result.get('recording-list'):
                match = result['recording-list'][0]
                
                clean_title = match.get('title', title)
                
                # Safely parse complex artist-credit nesting structures
                artist_credit = match.get('artist-credit', [{}])
                if artist_credit and isinstance(artist_credit[0], dict):
                    clean_artist = artist_credit[0].get('artist', {}).get('name', artist)
                else:
                    clean_artist = artist
                
                album_name = "Radio Rip"
                if match.get('release-list'):
                    album_name = match['release-list'][0].get('title', "Radio Rip")
                
                # Load and update metadata frames natively
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
