import sys
import time
import os
import fcntl
import sqlite3
import json
import musicbrainzngs
from mutagen.id3 import ID3, TIT2, TPE1, TALB, TCON, TXXX

musicbrainzngs.set_useragent("JakesRadioRipCustomTagger", "1.0", "ha-addon-user@example.com")

def init_tracking_db():
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

def is_already_processed_or_running(track_key):
    db_path = "/tmp/tagger_state.db"
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    try:
        cursor.execute('INSERT INTO processed_tracks (track_key, timestamp) VALUES (?, ?)', (track_key, int(time.time())))
        conn.commit()
        return False
    except sqlite3.IntegrityError:
        return True
    finally:
        conn.close()

def increment_duplicates_removed(count=1):
    dup_file = os.environ.get('DUPLICATES_REMOVED_FILE', '/media/stationripper/duplicates_removed.json')
    dup_lock = os.environ.get('DUPLICATES_REMOVED_LOCK', '/media/stationripper/duplicates_removed.lock')
    
    if not os.path.exists(dup_file):
        with open(dup_file, 'w') as f:
            f.write('{"count":0}')

    lock_file_path = dup_lock if os.path.exists(dup_lock) else dup_file
    with open(lock_file_path, 'r+') as lock_f:
        try:
            fcntl.flock(lock_f, fcntl.LOCK_EX)
            with open(dup_file, 'r+') as f:
                try: data = json.load(f)
                except Exception: data = {"count": 0}
                current = data.get('count', 0)
                data['count'] = (current if isinstance(current, int) else 0) + count
                f.seek(0)
                json.dump(data, f)
                f.truncate()
        finally:
            fcntl.flock(lock_f, fcntl.LOCK_UN)

def clean_and_tag_file(file_path, raw_title):
    if not os.path.exists(file_path):
        return

    is_duplicate_file = raw_title.endswith(' (1)')
    title_clean = raw_title[:-4] if is_duplicate_file else raw_title

    track_lookup_key = title_clean.strip().lower()
    if not track_lookup_key or " - " not in title_clean:
        return

    init_tracking_db()
    if is_already_processed_or_running(track_lookup_key):
        should_purge = os.environ.get('PURGE_DUPLICATES', 'true').lower() == 'true'
        if should_purge and is_duplicate_file and os.path.exists(file_path):
            print(f"🧹 [Tagger] Purging duplicate rip file: {raw_title}.mp3")
            try:
                os.remove(file_path)
                increment_duplicates_removed(1)
            except Exception as e:
                print(f"⚠️ Could not delete duplicate file: {e}")
        return

    try:
        audio = ID3(file_path)
    except Exception:
        audio = ID3()

    if 'TXXX:MusicBrainz Recording Id' in audio:
        return

    artist, title = title_clean.split(" - ", 1)
    search_artist = artist.strip()
    search_title = title.strip()

    lock_file_path = "/tmp/musicbrainz_api.lock"
    if not os.path.exists(lock_file_path):
        try:
            with open(lock_file_path, "w") as f: f.write("")
        except Exception: pass

    with open(lock_file_path, "w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX) 
        time.sleep(2.0)

        try:
            print(f"Querying MusicBrainz for: {search_artist} - {search_title}")
            result = musicbrainzngs.search_recordings(artist=search_artist, recording=search_title, limit=1)
            
            if result.get('recording-list'):
                match = result['recording-list'][0]
                
                clean_title = match.get('title', search_title)
                credits_list = match.get('artist-credit', [{}])
                clean_artist = credits_list[0].get('artist', {}).get('name', search_artist) if (credits_list and isinstance(credits_list, list)) else search_artist
                
                # Check for mismatch
                if search_artist.lower() not in clean_artist.lower() and clean_artist.lower() not in search_artist.lower():
                    print(f"❌ Match rejected (Artist Mismatch): '{search_artist}' vs '{clean_artist}'")
                    return
                if search_title.lower() not in clean_title.lower() and clean_title.lower() not in search_title.lower():
                    print(f"❌ Match rejected (Title Mismatch): '{search_title}' vs '{clean_title}'")
                    return

                album_name = "Jakes Rip"
                release_list = match.get('release-list', [])
                
                genre_name = "Ripped"
                tag_list = match.get('tag-list', [])
                
                if not tag_list and release_list and isinstance(release_list, list) and len(release_list) > 0:
                    tag_list = release_list[0].get('tag-list', [])
                
                if tag_list and isinstance(tag_list, list) and len(tag_list) > 0:
                    sorted_tags = sorted(tag_list, key=lambda x: int(x.get('count', 0)), reverse=True)
                    genre_name = sorted_tags[0].get('name', genre_name).title()

                if release_list and isinstance(release_list, list) and len(release_list) > 0:
                    album_name = release_list[0].get('title', "Radio Rip")
                
                # Save core ID3 tags natively
                audio['TIT2'] = TIT2(encoding=3, text=clean_title)
                audio['TPE1'] = TPE1(encoding=3, text=clean_artist)
                audio['TALB'] = TALB(encoding=3, text=album_name)
                audio['TCON'] = TCON(encoding=3, text=genre_name)
                
                # Inject Custom TXXX text tags for standard tracking IDs (Read by Home Assistant)
                audio['TXXX:MusicBrainz Recording Id'] = TXXX(encoding=3, desc='MusicBrainz Recording Id', text=match['id'])
                
                if credits_list and isinstance(credits_list, list) and len(credits_list) > 0:
                    artist_id = credits_list[0].get('artist', {}).get('id')
                    if artist_id:
                        audio['TXXX:MusicBrainz Artist Id'] = TXXX(encoding=3, desc='MusicBrainz Artist Id', text=artist_id)

                audio.save(file_path)
                print(f"Successfully tagged: {clean_artist} - {clean_title} [Album: {album_name}] [Genre: {genre_name}]")
            else:
                print(f"No match found for: {raw_title}")
                
        except Exception as e:
            print(f"Metadata processing failure: {e}")

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        clean_and_tag_file(sys.argv[1], sys.argv[2])
