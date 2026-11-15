<div align="right">

[![CI](https://img.shields.io/github/actions/workflow/status/Arata1202/PocketVideo/ci.yml?branch=main)](https://github.com/Arata1202/PocketVideo/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/github/license/Arata1202/PocketVideo)](LICENSE)

</div>

# Pocket Video

Pocket Video is a free iOS video player for videos saved in Files.

[Download on the App Store](https://apps.apple.com/jp/app/pocket-video/id6783846586)

## Features

- Open videos from the Files app or the share sheet
- Resume recently opened videos from where you left off
- Play videos using AirPlay or an external display
- Play videos in Picture in Picture

## Development Setup

You need macOS and Xcode 26 or later. The app supports iOS 17 and later.
The Xcode project is generated from `project.yml` using XcodeGen.
The following instructions use [Homebrew](https://brew.sh/).

```bash
git clone https://github.com/Arata1202/PocketVideo.git
cd PocketVideo
brew install xcodegen
xcodegen generate
open PocketVideo.xcodeproj
```

In Xcode, select the `PocketVideo` scheme and an iOS simulator, then run the app.
To run on a physical device, select your development team under Signing & Capabilities.

## Testing

```bash
xcodebuild -project PocketVideo.xcodeproj -scheme PocketVideo -showdestinations
xcodebuild -project PocketVideo.xcodeproj -scheme PocketVideo -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Replace `iPhone 16` with an available simulator name shown by the first command.
CI builds for the simulator and runs unit tests.
For changes involving AirPlay or external displays, also test on compatible physical devices.

## Technology Stack

| Category    | Technology Stack                   |
| ----------- | ---------------------------------- |
| App         | Swift, SwiftUI                     |
| Media       | AVFoundation, AVKit, MediaPlayer   |
| Development | Xcode, XcodeGen                    |
| Testing     | XCTest                             |
| CI          | GitHub Actions                     |
| Design      | Figma                              |

## Repository Structure

```text
PocketVideo/       App source
PocketVideoTests/  Unit tests
Brand/             App icon
project.yml        XcodeGen project definition
```

Design resources are available on [Figma](https://www.figma.com/design/l0hfS00kcTqVAzCtJFLiGZ/).

## Contributing

Bug reports, feature suggestions, documentation fixes, and pull requests are welcome.
See the [contribution guide](CONTRIBUTING.md) for details.

## License

[MIT License](LICENSE)
