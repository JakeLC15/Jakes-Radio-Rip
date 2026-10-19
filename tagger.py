import sys
import time
import os
import fcntl
import musicbrainzngs
from mutagen.id3 import ID3, TIT2, TPE1, TALB, TCON, TRCK, TDRC, TPE2, TXXX

musicbrainzngs.set_useragent("JakesRadioRipCustomTagger", "1.0", "ha-addon-user@example.com")

def clean_and_tag_file(file_path, raw_title):
    if not os.path.exists(file_path):
        return

    try:
        audio = ID3(file_path)
    except Exception:
        audio = ID3()

    # If it already has our custom MusicBrainz tag, stop immediately!
    if 'TXXX:MusicBrainz Recording Id' in audio:
        print(f"✅ [Tagger] Skipping file (Already fully tagged with MBID): {raw_title}.mp3")
        return

    if " - " in raw_title:
        artist, title = raw_title.split(" - ", 1)
    else:
        return

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
            
            if result.get('recording-list') and len(result['recording-list']) > 0:
                match = result['recording-list'][0]
                
                clean_title = match.get('title', search_title)
                credits_list = match.get('artist-credit', [{}])
                
                if credits_list and isinstance(credits_list, list) and len(credits_list) > 0:
                    clean_artist = credits_list[0].get('artist', {}).get('name', search_artist)
                    artist_id = credits_list[0].get('artist', {}).get('id')
                else:
                    clean_artist = search_artist
                    artist_id = None
                
                # STRING NORMALIZATION HELPERS FOR VALIDATION
                def normalize_str(s):
                    removals = ["'", "’", '"', "“", "”", "-", ".", ",", "!", "?", "(", ")", "[", "]"]
                    out = s.lower().strip()
                    for char in removals:
                        out = out.replace(char, "")
                    return " ".join(out.split())

                if normalize_str(search_artist) not in normalize_str(clean_artist) and normalize_str(clean_artist) not in normalize_str(search_artist):
                    print(f"❌ Match rejected (Artist Mismatch): '{search_artist}' vs '{clean_artist}'")
                    return
                if normalize_str(search_title) not in normalize_str(clean_title) and normalize_str(clean_title) not in normalize_str(search_title):
                    print(f"❌ Match rejected (Title Mismatch): '{search_title}' vs '{clean_title}'")
                    return

                album_name = "Jakes Rip"
                track_num = "1"
                release_date = ""
                rg_id = None
                
                release_list = match.get('release-list', [])
                
                # --- ROBUST MULTI-GENRE HARVESTING ---
                raw_genres = []
                if 'tag-list' in match:
                    raw_genres.extend(match['tag-list'])
                
                if isinstance(release_list, list) and len(release_list) > 0:
                    first_release = release_list[0]
                    album_name = first_release.get('title', "Radio Rip")
                    release_date = first_release.get('date', '')
                    
                    if first_release.get('medium-list') and len(first_release['medium-list']) > 0:
                        track_list = first_release['medium-list'][0].get('track-list', [])
                        if track_list and len(track_list) > 0:
                            track_num = str(track_list[0].get('number', '1'))

                    if 'tag-list' in first_release:
                        raw_genres.extend(first_release['tag-list'])
                    
                    rg_id = first_release.get('release-group', {}).get('id')
                    if rg_id:
                        try:
                            rg_data = musicbrainzngs.get_release_group_by_id(rg_id, includes=['tags'])
                            if rg_data.get('release-group', {}).get('tag-list'):
                                raw_genres.extend(rg_data['release-group']['tag-list'])
                        except Exception:
                            pass

                if not raw_genres and artist_id:
                    try:
                        artist_data = musicbrainzngs.get_artist_by_id(artist_id, includes=['tags'])
                        if artist_data.get('artist', {}).get('tag-list'):
                            raw_genres.extend(artist_data['artist']['tag-list'])
                    except Exception:
                        pass

                genre_final_list = []
                if raw_genres:
                    genre_scores = {}
                    for tag in raw_genres:
                        name = tag.get('name', '').lower().strip()
                        count = int(tag.get('count', 1))
                        if not name or name in ['rock', 'pop', 'american', 'usa', 'band', 'male vocal']:
                            continue
                        genre_scores[name] = genre_scores.get(name, 0) + count
                    
                    sorted_genres = sorted(genre_scores.items(), key=lambda x: x[1], reverse=True)
                    genre_final_list = [g[0].title() for g in sorted_genres[:3]]

                genre_name = "; ".join(genre_final_list) if genre_final_list else "Rock"

                # Save ID3 tags natively
                audio['TIT2'] = TIT2(encoding=3, text=clean_title)
                audio['TPE1'] = TPE1(encoding=3, text=clean_artist)
                audio['TALB'] = TALB(encoding=3, text=album_name)
                audio['TCON'] = TCON(encoding=3, text=genre_name)
                audio['TRCK'] = TRCK(encoding=3, text=track_num)
                audio['TPE2'] = TPE2(encoding=3, text=clean_artist)
                
                if release_date:
                    year_only = release_date.split('-')[0]
                    audio['TDRC'] = TDRC(encoding=3, text=year_only)
                
                audio['TXXX:MusicBrainz Recording Id'] = TXXX(encoding=3, desc='MusicBrainz Recording Id', text=match['id'])
                if artist_id:
                    audio['TXXX:MusicBrainz Artist Id'] = TXXX(encoding=3, desc='MusicBrainz Artist Id', text=artist_id)
                if rg_id:
                    audio['TXXX:MusicBrainz Release Group Id'] = TXXX(encoding=3, desc='MusicBrainz Release Group Id', text=rg_id)

                audio.save(file_path)
                print(f"Successfully tagged: {clean_artist} - {clean_title} [Album: {album_name}] [Track #: {track_num}] [Year: {release_date[:4]}] [Genre: {genre_name}]")
            else:
                print(f"No match found for: {raw_title}")
                
        except Exception as e:
            print(f"Metadata processing failure: {e}")

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        clean_and_tag_file(sys.argv[1], sys.argv[2])
