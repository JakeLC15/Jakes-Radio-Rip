# Changelog

## 2026.10.03-7
- **Added:** Refactor button styles and add refresh functionality

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
