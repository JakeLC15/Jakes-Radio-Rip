# Changelog

## 2026.10.03-2
- **Added:** Direct Home Assistant HTTP API integration to push track counts automatically.
- **Added:** Front-end log suppression toggle option via `--quiet`.
- **Fixed:** Avoid container timeout crashes by implementing non-blocking STDIN stream listeners.

## 2026.10.02-1
- **Added:** Track cleanup sequence using BusyBox safe nul-terminated arguments.
- **Fixed:** Prevent overwriting tracks by applying `-o always` flag behaviors.
