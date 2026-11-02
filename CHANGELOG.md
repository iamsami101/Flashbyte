# Changelog

## Unreleased

- Receive tab device name field now shows "Creating your name..." hint when the field is empty
- Device name now defaults to the device's model name on first launch instead of a random two-word name
- Added a "reset" (cross) icon next to the name-refresh button in the receive tab; it appears when the name differs from the device model name and restores the model name when tapped
- Added `device_info_plus` dependency to retrieve the real device model name
- Android device name resolves to the model name (falls back to brand/manufacturer when the model is an internal code like "2201117TG"), then hostname, then "Unknown Device"
- Removed the word "abuse" from the random word list
- Added a trusted devices list keyed by each device's unique certificate fingerprint
- New "Always accept files from…" checkbox on the incoming files approval screen; checking it and accepting trusts the sender so future transfers are auto-accepted without the approval screen
- Subsequent files from a trusted sender during an active session are also accepted automatically
- New "Trusted devices" section in Settings showing trusted device names with option to remove them
- Trusted device names auto-update when a device is discovered or connects with a renamed profile
- Device certificate fingerprint is now always exchanged on connection (previously only with TLS enabled)
- Fixed crash when trusting the first device on the list (unmodifiable empty list)
