import sys
import time
import os
import fcntl
import sqlite3
import musicbrainzngs
from mutagen.id3 import ID3, TIT2, TPE1, TALB, TXXX

musicbrainzngs.set_useragent("JakesRadioRipCustomTagger", "1.0", "ha-addon-user@example.com")

def init_tracking_db():
    """Creates a lightning-fast local cache table to track processed songs."""
    db_path = "/tmp/tagger_state.db"
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS processed_tracks (
            track_key TEXT PRIMARY KEY,
            timestamp INTEGER
        )
    ''')
    conn.commit()
    return conn

def increment_duplicates_removed(count=1):
    """Safely increments the auto-purged duplicate track counter JSON with robust file locking."""
    dup_file = os.environ.get('DUPLICATES_REMOVED_FILE', '/media/stationripper/duplicates_removed.json')
    dup_lock = os.environ.get('DUPLICATES_REMOVED_LOCK', '/media/stationripper/duplicates_removed.lock')
    
    if not os.path.exists(dup_file):
        with open(dup_file, 'w') as f:
            f.write('{"count":0}')

    # Establish an explicit file handle lock to protect data alignment operations
    lock_file_path = dup_lock if os.path.exists(dup_lock) else dup_file
    with open(lock_file_path, 'r+') as lock_f:
        try:
            fcntl.flock(lock_f, fcntl.LOCK_EX)
            
            with open(dup_file, 'r+') as f:
                try:
                    data = json.load(f)
                except Exception:
                    data = {"count": 0}
                
                current = data.get('count', 0)
                if not isinstance(current, int):
                    current = 0
                
                data['count'] = current + count
                
                f.seek(0)
                json.dump(data, f)
                f.truncate()
        finally:
            fcntl.flock(lock_f, fcntl.LOCK_UN)

def is_already_processed_or_running(track_key):
    """Checks and sets the lock state atomically to defeat parallel process races."""
    db_path = "/tmp/tagger_state.db"
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    try:
        # Atomic insertion will fail immediately if another thread is processing this track key string
        cursor.execute('INSERT INTO processed_tracks (track_key, timestamp) VALUES (?, ?)', (track_key, int(time.time())))
        conn.commit()
        return False
    except sqlite3.IntegrityError:
        # Key already exists in database block, drop process execution thread
        return True
    finally:
        conn.close()

def clean_and_tag_file(file_path, raw_title):
    if not os.path.exists(file_path):
        return

    # Clear trailing duplicate digits appended by stream managers
    title_clean = raw_title
    if title_clean.endswith(' (1)'):
        title_clean = title_clean[:-4]

    # Normalize track lookup fingerprint string key identifier target
    track_lookup_key = title_clean.strip().lower()
    if not track_lookup_key or " - " not in title_clean:
        return

    # DATABASE GATING BLOCK
    init_tracking_db()
    if is_already_processed_or_running(track_lookup_key):
        should_purge = os.environ.get('PURGE_DUPLICATES', 'true').lower() == 'true'

        if should_purge and is_duplicate_file and os.path.exists(file_path):
            print(f"🧹 [Tagger] Purging duplicate rip file: {raw_title}.mp3")
            try:
                os.remove(file_path)
                # AUTOMATION TRIGGER: Increment the metric file immediately on successful deletion
                increment_duplicates_removed(1)
            except Exception as e:
                print(f"⚠️ Could not delete duplicate file: {e}")
        return

    # Open the audio file using standard ID3 layout to inspect it 
    try:
        audio = ID3(file_path)
    except Exception:
        audio = ID3()

    # Second check safety valve
    if 'TXXX:MusicBrainz Recording Id' in audio:
        return

    artist, title = title_clean.split(" - ", 1)

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
                
                # Access index 0 of the list before pulling nested artist details
                credits_list = match.get('artist-credit', [{}])
                if credits_list and isinstance(credits_list, list) and len(credits_list) > 0:
                    clean_artist = credits_list[0].get('artist', {}).get('name', artist.strip())
                else:
                    clean_artist = artist.strip()
                
                # Access index 0 of the list before pulling nested release/album titles
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
