# Experiments

`run-spotify.sh` records the screen (`screencapture -v`) and the unified log while Traceless
launches with `--select Spotify --demo-uninstall`. Recordings and logs stay local (see .gitignore).

## Run 1 — Spotify web app on macOS 26.7.1 (2026-10-30)
- 62 apps measured in 4.1 s (30.84 GB).
- Spotify was a Safari web app; Traceless also found 537 MB left by an older desktop Spotify
  (`com.spotify.client`). 11 items, 537.8 MB, moved to the Trash in under a second.
- Bugs found: ~10 s UI freeze (removal ran on the main thread), duplicate PID in the log,
  Launch Services unregistered after the bundle had moved (exit 1).

## Restore test
All 10 items went back to their exact paths through App › Restore Last Uninstall.

## Run 2 — after fixes
No freeze; result screen right after confirming; "Verified: 10 of 10 removed paths are gone".
