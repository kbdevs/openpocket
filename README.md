# OpenPocket

An open-source iPhone app for the Pocket voice recorder. It pairs with the
recorder over Bluetooth, syncs recordings over Bluetooth or the recorder's
Wi-Fi, and plays them back. It sends audio to Deepgram for transcription and
speaker labels, and transcripts to OpenRouter for notes, titles and questions.
You supply the API keys.

Not affiliated with or endorsed by Pocket. "Pocket" is used only to name the
recorder this app works with.

## Features

- Pair once. The app saves the pairing key in Keychain and reconnects to the
  recorder on launch and after a dropped link.
- Bluetooth sync, and fast Wi-Fi sync through the recorder's own network.
  Wi-Fi falls back to Bluetooth when the recorder battery is 10% or lower.
- Auto sync: new recordings download when the recorder connects or a
  recording stops.
- Live transcript while the recorder records, from its live audio stream.
- Transcription with speaker labels, AI notes, action items and a short title.
  Built-in and custom note styles.
- Ask questions about one recording or across all recordings.
- People: name speakers once, see their recordings, rename or merge names.
- On-device voice profile that suggests which speaker is you.
- Notifications when a recording is processed and when the recorder battery
  is low.
- Recordings grouped by day, search, folders, bookmarks, playback speed,
  Markdown export.
- Experimental: start and stop a recording from the phone.

## Requirements

- Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0
  or later.
- iOS 17 or later.
- A paid Apple developer account for a physical device. Automatic Wi-Fi joining
  uses the Hotspot Configuration capability.
- A [Deepgram](https://deepgram.com) key and an [OpenRouter](https://openrouter.ai) key.

## Build

```sh
./scripts/build-ios.sh          # simulator build
./scripts/build-ios.sh test     # unit tests (SIMULATOR_NAME or SIMULATOR_ID)
```

The script downloads the pinned Apache-2.0 speaker model (38.8 MB), checks its
SHA-256, then generates `ios/PocketBridge.xcodeproj`. Open the project, set your
team and bundle identifier, and run the PocketBridge scheme on your iPhone.

## API keys

Create `ios/PocketBridge/Keys/PocketBridgeAI.plist`. Git ignores this folder.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DEEPGRAM_API_KEY</key>
	<string>your-deepgram-key</string>
	<key>OPENROUTER_API_KEY</key>
	<string>your-openrouter-key</string>
	<key>OPENROUTER_MODEL</key>
	<string>google/gemini-2.5-flash</string>
</dict>
</plist>
```

Keys inside an app bundle can be extracted. Use keys with spending limits and
do not share the built app.

## First pairing

The recorder pairs with one app at a time. Reset it first: close the Pocket
app, triple-click the side button (the light blinks red), then hold the button
until the red blinking stops and the light pulses blue. Open OpenPocket and
follow the onboarding.

## Project layout

| Path | Contents |
| --- | --- |
| `ios/PocketBridge` | SwiftUI app |
| `ios/PocketBridgeTests` | Unit tests |
| `docs/protocol-reference.md` | Recorder Bluetooth and Wi-Fi protocol |
| `backend/` | Optional self-hosted processing service (not used by default) |
| `scripts/` | Build and model scripts |

## Credits

Protocol details come from [pocket-libre](https://github.com/shahcolate/pocket-libre).
Speaker matching uses an ECAPA-TDNN Core ML model; see
`ios/PocketBridge/ThirdPartyNotices.txt`.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md). You may use, change and share this
code for any noncommercial purpose. Commercial use needs separate permission.
