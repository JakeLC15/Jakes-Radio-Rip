<table style="border: none;">
  <tr>
    <td style="border: none;">
      <img width="100" height="100" alt="Jakes_station_rip_icon" src="https://github.com/user-attachments/assets/9f8d8a25-618e-4aa5-8f6c-e110db827c32" />
    </td>
    <td style="border: none;">
      <h1>Jake's Station Rip Tool</h1>
    </td>
  </tr>
</table>

### This a lightweight Home Assistant Add-on that uses optimized background streams to rip multiple internet radio stations simultaneously. Songs are tagged with metadata from MusicBrainz and ready for Music Assistant. 

**This is for personal use only and you are responsible for use and your own actions!**

>Working for more streams thanks to qbus00
https://github.com/qbus00/streamripper.git

## 📻 Features:

- Multi-Stream Audio Capture: Rips multiple streams at the same time in the background.

- Auto-Tagging: Automatically splits tracks and adds metadata tags using musicbrainz.

- Tag editor: See tag info. Edit title to correct naming and auto tagging runs. Filter tracks by tagging status to find tracks easier.

- Ingress Web UI & Sidebar Integration: Monitor your live stream statuses, track tallies, disk usage, connection history, ads removed and recent tracks directly from your Home Assistant sidebar.

- NAS storage protection. Configure a NAS status sensor to pause streamripper if NAS goes offline and automatically restart if reconnected.
  Protects local storage from filling from home assistant silently defaulting to local storage when NAS is offline.

- One-Click Library Maintenance: Includes a built-in button to instantly purge numbered duplicate tracks Track - Artist(2).mp3, etc.) on the fly.
- Or it can remove duplicates automatically.
  
- Configurable minimum track size to keep. Recordings that are smaller are considered ads and the count is shown in the UI.
  
- Continuous recording mode for podcast or live stream type stations. Configure the url and run an automation in Home Assistant to start and stop the app.

- Find stream urls here: https://streamurl.link/

- YouTube download is for your own uploaded video or authorized youtube content.
Save individual audio or a playlist(batch mode).
May require youtube_cookies.txt file for authorization. **Don't share this file.**

- Get cookie file with firefox extension https://addons.mozilla.org/en-US/firefox/addon/yt-dlp-cookie-exporter/
Rename it to youtube_cookies.txt and put it in share folder. /share/youtube_cookies.txt

- YouTube download is not so lightweight. 20-25% cpu on rpi4 compared to 0.2% with multiple streamripper.

## Installation

- The easy way!

<a href="https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FJakeLC15%2FJakes-Radio-Rip"><img src="https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg" alt="add repo"></a>

- Manually!

Home Assistant add-on

Settings > Add-ons > Plus > Repositories > Add
https://github.com/JakeLC15/Jakes-Radio-Rip.git


Jakes Station Rip Tool > Install > Start

### Optional: Add this to configuration.yaml for media access:
Remember to restart Home Assistant! 
```
homeassistant:
  media_dirs:
    local: /media
```

### NAS or external drive recommended. 

## Example

📻 Live Stream Status

    🟢 jakes_station.com Ripping
    🟢 stream.jakes.de Ripping
    🟢 ec3.jakes.net:2770 Ripping
    🟢 streams.jakes.de Ripping
    🟢 200.200.86.16:80 Ripping
    🟢 listen.306fm.com Ripping

🎵 Current Track

Aerosmith - I Dont Want To Miss A Thing

📊 Library
Total Tracks
10719
Tracks Today
2084
Ads Removed
2266
Files smaller than 1.0 MB
Duplicates Removed
233

Disk Used
104.8 GB
Disk Free
349.8 GB
Disk Total
469.4 GB
Disk Usage
22.3%
Uptime
12h 25m 22s

🔄 Connection History

🕘 Recent Tracks

    Aerosmith - I Dont Want To Miss A Thing
    📁 Jakes Rock · ⏱️ 09:55:38
    Amorphis - Amongst stars
    📁 Jakes Modern Metal · ⏱️ 09:55:23
    Dustin Lynch, MacKenzie Porter - Thinking `Bout You (feat. MacKenzie Porter)
    📁 306FM Legends of Country · ⏱️ 09:54:58
    Godsmack - When Legends Rise
    📁 Jakes - Post Grunge Rock · ⏱️ 09:54:49
    Dredg - Bug eyes
    📁 Jakes Modern Rock · ⏱️ 09:54:07
    The Black Keys - You Got to Lose
    📁 Jakes Alternative · ⏱️ 09:53:57
    Clay Walker - Dreaming With My Eyes Open (Single Version)
    📁 306.FM 90s Country · ⏱️ 09:53:41
    Badflower - Promise Me
    📁 Jakes - Alternative Rock · ⏱️ 09:53:34
    Bush - Creatures of the fire
    📁 Jakes Grunge · ⏱️ 09:53:15
    Styx - Shooz
    📁 Jakes Classic Rock · ⏱️ 09:52:47


>While this is a working addon, it is still a work in progress and features may be added and removed. It also relies on multiple outside sources that are constantly changing and updating!

**Let me know if you run into any bugs or have feature suggestions!**

## Disclaimer
This software is developed and provided strictly for educational, research, and personal archiving purposes. The developer does not condone, promote, or encourage the unauthorized downloading or distribution of copyrighted material. 
Users are solely responsible for ensuring that their use of this tool complies with local laws, regulations, and the Terms of Service of any streaming platforms or radio stations accessed. The developer assumes no liability for any misuse of this software or any copyright infringement committed by the end-user. 
blah blah blah! Don't do dumb stuff!
