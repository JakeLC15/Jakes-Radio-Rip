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

### This a lightweight Home Assistant Add-on that uses optimized background streams to rip multiple internet radio stations simultaneously.

**This is for personal use only and you are responsible for use and your own actions!**

>Working for more streams thanks to qbus00
https://github.com/qbus00/streamripper.git

## 📻 Features:

- Multi-Stream Audio Capture: Rips multiple streams at the same time in the background.

- Auto-Tagging: Automatically splits tracks and adds metadata tags using stream data.

- Ingress Web UI & Sidebar Integration: Monitor your live stream statuses, track tallies, disk usage, connection history and recent tracks directly from your Home Assistant sidebar.

- One-Click Library Maintenance: Includes a built-in button to instantly purge numbered duplicate tracks Track - Artist(2).mp3, etc.) on the fly.
  
- Configurable minimum track size to keep. Recordings that are smaller are considered ads and the count is shown in the UI.
  
- Continuous recording mode for podcast or live stream type stations. Configure the url and run an automation in Home Assistant to start and stop the app.

## Installation

- The easy way!

<a href="https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FJakeLC15%2FJakes-Radio-Rip"><img src="https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg" alt="add repo"></a>

- Manually!

Home Assistant add-on

Settings > Add-ons > Plus > Repositories > Add
https://github.com/JakeLC15/Jakes-Radio-Rip.git


Jakes Station Rip Tool > Install > Start

### Add this to configuration.yaml for media access:
Remember to restart Home Assistant! 
```
homeassistant:
  media_dirs:
    local: /media
```

## Example

📻 Live Stream Status

    🟢 bigrradio.cdnstream1.com Ripping
    🟢 stream.rockantenne.de Ripping
    🟢 ec3.yesstreaming.net:2770 Ripping
    🟢 streams.radiobob.de Ripping
    🟢 216.235.82.16:80 Ripping
    🟢 listen.181fm.com Ripping

🎵 Current Track

Aerosmith - I Dont Want To Miss A Thing

📊 Library

Total Tracks
7002 \
Tracks Today
1873 \
Disk Used
80.9 GB \
Disk Free
373.6 GB \
Disk Total
469.4 GB \
Disk Usage
17.2% \
Uptime
13h 17m

🔄 Connection History

    bigrradio.cdnstream1.com
    0 reconnects
    stream.rockantenne.de
    0 reconnects
    ec3.yesstreaming.net:2770
    0 reconnects
    streams.radiobob.de
    0 reconnects
    216.235.82.16:80
    0 reconnects
    listen.181fm.com
    0 reconnects

🕘 Recent Tracks

    Aerosmith - I Dont Want To Miss A Thing
    📁 ROCK ANTENNE 90er Rock · ⏱️ 09:55:38
    Amorphis - Amongst stars
    📁 ROCK ANTENNE Modern Metal · ⏱️ 09:55:23
    Dustin Lynch, MacKenzie Porter - Thinking `Bout You (feat. MacKenzie Porter)
    📁 113FM Legends of Country · ⏱️ 09:54:58
    Godsmack - When Legends Rise
    📁 BigR - Post Grunge Rock · ⏱️ 09:54:49
    Dredg - Bug eyes
    📁 ROCK ANTENNE Modern Rock · ⏱️ 09:54:07
    The Black Keys - You Got to Lose
    📁 ROCK ANTENNE Alternative · ⏱️ 09:53:57
    Clay Walker - Dreaming With My Eyes Open (Single Version)
    📁 181.FM 90s Country · ⏱️ 09:53:41
    Badflower - Promise Me
    📁 RADIO BOB - Alternative Rock · ⏱️ 09:53:34
    Bush - Creatures of the fire
    📁 ROCK ANTENNE Grunge · ⏱️ 09:53:15
    Styx - Shooz
    📁 Badlands Classic Rock · ⏱️ 09:52:47


>While this is a working addon, it is still a work in progress and features may be added and removed.

**Let me know if you run into any bugs or have feature suggestions!**
