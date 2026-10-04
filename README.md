<img width="100" height="100" alt="Jakes_station_rip_icon" src="https://github.com/user-attachments/assets/9f8d8a25-618e-4aa5-8f6c-e110db827c32" /> 

# Jake's Station Rip Tool

### This a lightweight Home Assistant Add-on that uses optimized background streams to rip multiple internet radio stations simultaneously.

**This is for personal use only and you are responsible for use and your own actions!**

>Working for more streams thanks to qbus00
https://github.com/qbus00/streamripper.git

## 📻 Features:

- Multi-Stream Audio Capture: Rips multiple streams at the same time in the background.

- Auto-Tagging: Automatically splits tracks and adds metadata tags using stream data.

- Ingress Web UI & Sidebar Integration: Monitor your live stream statuses and track tallies directly from your Home Assistant sidebar.

- One-Click Library Maintenance: Includes a built-in button to instantly purge numbered duplicate tracks ((1).mp3, etc.) on the fly.

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

<img width="600" height="1000" alt="Screenshot_20261004-095516_Home Assistant" src="https://github.com/user-attachments/assets/b1b20c37-486e-4f67-91d0-9535edc153fc" />


>While this is a working addon, it is still a work in progress and features may be added and removed.

**Let me know if you run into any bugs or have feature suggestions!**
