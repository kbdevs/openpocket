# Device protocol source

The initial Swift transport uses the public device captures in
[pocket-libre](https://github.com/shahcolate/pocket-libre), commit
`5962722710731edbc9a2da22149f0e4fe198366e`.

The project records Bluetooth and Wi-Fi transfers on firmware 1.7 and 1.8.
It identifies MP3 audio, ASCII `APP&` commands, the primary GATT service, and
the Wi-Fi TCP transfer. Its notes distinguish captured facts from guesses.
The Swift code uses those facts. It does not implement guessed commands.

A public capture does not prove a transfer on this iPhone app. Check Bluetooth
and Wi-Fi transfer on the recorder before relying on either transport.

The capture reports that a reset recorder stores the first 16-character key
sent with `APP&SK&`. Pair Pocket creates a random key for that recorder and
saves it in Keychain before connecting. Retries reuse the saved key, including
when an authentication reply is lost. An existing key can be entered for a
recorder that is still paired with another app.

The first connection enables A3 reply notifications before it sends the
23-byte ASCII `APP&SK&<key>` frame, with no newline or NUL. The app uses a
writable A2 control characteristic, or the captured A3 route when A2 cannot
write. After `MCU&SK&OK`, Pair Pocket closes the link, waits two seconds,
then reconnects and sends the same key. It tries the reconnect up to three
times. It does not require `MCU&WIFIO` or wait for the recorder to close the
first link. A1 audio notifications start when a download starts. Wi-Fi also
needs that subscription because its transfer starts over Bluetooth before
the app sends `APP&U&WIFI`. The audio channel cannot block pairing.

If setup fails, the connection report records the setup step, discovered
characteristic properties, notification state and command byte limits. It
omits pairing keys, Wi-Fi credentials, recording names and audio.

After an accepted session drops, the app reconnects with the same saved key.
It waits for the old CoreBluetooth request to end, pauses while Bluetooth is off,
and uses a capped retry delay. Disconnect stops these retries. Stop during a
file transfer keeps the connection monitor active and removes the partial copy.

Battery readings are percentages, with zero included. Each link starts with no
battery value. The app reads the captured vendor command and, when available,
the standard Battery Service. The standard service is optional and cannot block
pairing. If the two valid values differ, the app reports the conflict instead
of choosing a value. Refresh battery reads both again. A connection report
includes numeric battery readings and their source. Neither battery source
has been verified on this user's recorder in the new app.

The app never sends delete, reset, firmware update, or key replacement commands.
It keeps pairing keys on the iPhone and does not send them to the AI service.

## Third-party notice

MIT License

Copyright (c) 2026 Shah Baig

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
