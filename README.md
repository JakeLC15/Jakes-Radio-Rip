# Jakes Station Rip Tool
### Home assistant addon to rip songs from online radio. 

This is for personal use only and you are responsible for use and your own actions!

>Working for more streams thanks to qbus00
https://github.com/qbus00/streamripper.git

## Installation
Home Assistant add-on


Settings > Add-ons > Plus > Repositories > Add
https://github.com/JakeLC15/Jakes-Radio-Rip.git


Jakes Station Rip Tool > Install > Start

## Examples
Sensor Example:
```
command_line:
  - sensor:
      name: "Ripped Music Count"
      unique_id: ripped_music_count_recursive
      command: "find /media/DATA2/Music/jakes_station_rip f -name '*.mp3' | wc -l"
      scan_interval: 600 # Updates every 10 minutes (in seconds)
      value_template: "{{ value | int }}"

  - sensor:
      name: Station Ripper Status
      command: "cat /media/DATA2/Music/jakes_station_rip/status.json"
      # This stores the entire raw JSON string inside the sensor state
      value_template: "{{ value }}"
      scan_interval: 20
```

Card Example:
```
type: markdown
title: 📻 Jake's Station Ripper
content: >
  {% set raw_state = states('sensor.station_ripper_status') %} {% if raw_state
  not in ['unknown', 'unavailable', 'Active'] and raw_state | trim != '' %}
    {% set data = raw_state | from_json %}
    {% for station, status in data.items() %}
    **{{ station }}**  
    Status: 
    {% if status == 'Connecting' %}
    🟢 Ripping (Active)
    {% elif status == 'Offline' %}
    🔴 Offline
    {% else %}
    🟢 Online ({{ status }})
    {% endif %}
      
    ---
    {% endfor %}
  {% else %}
    ⏳ Waiting for stream status data...
  {% endif %}


  ### 📥 **Total Tracks Ripped:** {{ states('sensor.ripped_music_count') }}
  files
tap_action:
  action: navigate
  navigation_path: /media-browser/local/DATA2/Music/jakes_station_rip
```

<img width="720" height="664" alt="Screenshot_20261003-094019_Home Assistant" src="https://github.com/user-attachments/assets/3dad93c3-b9dd-4d35-8190-d48350355465" />
