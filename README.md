# Shelly BLU RC Button 4 ZB — Production SmartThings Edge Driver v1.0.1

## SmartThings events

Each physical key is exposed as its own component:

- Button 1
- Button 2
- Button 3
- Button 4

Supported routine triggers:

- Pressed
- Double pressed
- Pressed 3 times
- Held

The driver supports Shelly's default On/Off mode and its optional Toggle mode.

## Installation

```bash
cd ~/Downloads/shelly-blu-rc4-production
smartthings edge:drivers:package .   --channel 6a593b81-e426-4303-8137-c7878c81a8a5   --install
```

After installing, remove and re-pair the remote so the new package fingerprint
claims it. Keep the diagnostic driver installed until the production driver has
successfully paired and displayed all four buttons.

If button events do not arrive immediately, start logcat for the production
driver, tap Refresh in the SmartThings device page, and repeatedly press a
remote button for about 10 seconds so the sleeping remote receives the binding
requests.


## v1.0.1

- Suppresses the extra `pushed` event generated when a held button is released.
- Normal short presses, double presses, triple presses, and held events remain unchanged.
