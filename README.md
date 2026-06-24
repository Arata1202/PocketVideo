# Pocket Video

Pocket Video is a simple iOS app for local video playback with AirPlay support.

It focuses on opening local video files from Files without copying them into app storage, playing them on iPhone or iPad, and sending playback to AirPlay devices such as Apple TV.

## Features

- Open local MP4 and MOV files from Files.
- Start playback from the selected file without copying the video into app storage.
- Play videos on iPhone and iPad.
- Send playback to AirPlay devices.
- Use the native Apple video player controls.
- Resume recently opened videos.
- Manage recently opened videos.
- Keep a lightweight recent videos list.
- Preserve the original video aspect ratio.
- Adapt the player layout for portrait, landscape, and vertical videos.

## Requirements

- iOS 17.0 or later
- Xcode
- XcodeGen

## Development

Generate the Xcode project:

```bash
brew install xcodegen
xcodegen generate
open MP4AirPlayPlayer.xcodeproj
```

Then select a development team in Xcode and build the app on Simulator or a real device.

AirPlay behavior should be tested on a real iPhone or iPad with an AirPlay receiver.

## Scope

This project focuses on local MP4 playback and AirPlay routing. Advanced media library features are intentionally kept out of the core experience.

## License

MIT
