# Changelog

## 2026.10.06-1
- **Added:** Configurable file size to remove ads or incomplete tracks.
- **Added:** Ad Counter in Web UI
- **Added:** Control for track being saved as individual or continuous. Adds ability to save podcast type streams.
## 2026.10.05-1
- **Added:** Web UI update to show more info
## 2026.10.04-1
- **Added:** Media button mapped to configured output directory.
- **Fixed:** No longer saving .cue file.
- **Added:** Multi-platform support.
## 2026.10.03-7
- **Added:** Refactor button styles and add refresh functionality
- **Added:** Button to media folder to open output directory

## 2026.10.03-6
- **Added:** Refactored ingress handling to use a Python-based multi-threaded server for web requests.

## 2026.10.03-5
- **Added:** Direct Home Assistant Ingress. Creates webserver management.
- **Fixed:** Removed `-o always` flag, handled natively.

## 2026.10.03-2
- **Added:** Direct Home Assistant HTTP API integration to push track counts automatically.
- **Added:** Front-end log suppression toggle option via `--quiet`.
- **Fixed:** Avoid container timeout crashes by implementing non-blocking STDIN stream listeners.

## 2026.10.02-1
- **Added:** Track cleanup sequence using BusyBox safe nul-terminated arguments.
- **Fixed:** Prevent overwriting tracks by applying `-o always` flag behaviors.
