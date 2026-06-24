# TODO

## Branding

- Review the generated `Pocket Video` AppIcon on a real device home screen.
- Review the launch screen timing and appearance on a real device.
- Verify first launch time after install is short enough.
- Prepare App Store subtitle and Japanese description.

## UI Polish

- Check recent video row spacing with thumbnails on device.
- Verify portrait, landscape, vertical, 16:9, and 4:3 playback layouts.
- Check whether landscape playback needs an explicit home/close affordance.
- Confirm AirPlay controls appear naturally on a real device.
- Confirm Picture in Picture appears and works on a real device.

## Playback Logic

- Verify large videos start quickly now that playback uses the original file instead of copying into app storage.
- Verify selected videos begin playback promptly without an extra bookmark-resolution round trip.
- Check whether thumbnail generation needs caching after real-device testing.
- Confirm recent videos reopen correctly after app relaunch.

## Release Check

- Run `xcodegen generate` on macOS.
- Build and test on a real iPhone.
- Confirm AppIcon rendering at small sizes.
