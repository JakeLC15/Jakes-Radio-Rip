import sys
import time
import os
import fcntl
import musicbrainzngs
from mutagen.id3 import ID3, TIT2, TPE1, TALB, TXXX

musicbrainzngs.set_useragent("JakesRadioRipCustomTagger", "1.0", "ha-addon-user@example.com")

def clean_and_tag_file(file_path, raw_title):
    if not os.path.exists(file_path):
        return

    # Open the audio file using standard ID3 layout to inspect it first
    try:
        audio = ID3(file_path)
    except Exception:
        # Create tags if the file completely lacks an ID3 header
        audio = ID3()

    # LIGHTWEIGHT GATE: If it already has our custom MusicBrainz tag, stop immediately!
    if 'TXXX:MusicBrainz Recording Id' in audio:
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
                 
                credits_list = match.get('artist-credit', [{}])
                if credits_list and isinstance(credits_list, list) and len(credits_list) > 0:
                    clean_artist = credits_list[0].get('artist', {}).get('name', artist.strip())
                else:
                    clean_artist = artist.strip()
                
                album_name = "Radio Rip"
                release_list = match.get('release-list', [])
                if release_list and isinstance(release_list, list) and len(release_list) > 0:
                    album_name = release_list[0].get('title', "Radio Rip")
                
                # Inject core tag frames natively into the audio profile binary destination blocks
                audio['TIT2'] = TIT2(encoding=3, text=clean_title)  # Title Frame
                audio['TPE1'] = TPE1(encoding=3, text=clean_artist) # Artist Frame
                audio['TALB'] = TALB(encoding=3, text=album_name)   # Album Frame
                
                # Inject Custom TXXX text tags for standard tracking IDs (Read by Home Assistant)
                audio['TXXX:MusicBrainz Recording Id'] = TXXX(encoding=3, desc='MusicBrainz Recording Id', text=match['id'])
                
                # Extract and assign artist track IDs if present in the lookup payload response 
                if credits_list and isinstance(credits_list, list) and len(credits_list) > 0:
                    artist_id = credits_list[0].get('artist', {}).get('id')
                    if artist_id:
                        audio['TXXX:MusicBrainz Artist Id'] = TXXX(encoding=3, desc='MusicBrainz Artist Id', text=artist_id)

                audio.save(file_path)
                print(f"Successfully tagged: {clean_artist} - {clean_title} [Album: {album_name}]")
            else:
                print(f"No match found for: {raw_title}")
                
        except Exception as e:
            print(f"Metadata processing failure: {e}")

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        clean_and_tag_file(sys.argv[1], sys.argv[2])
