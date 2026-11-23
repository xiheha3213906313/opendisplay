# Android system audio attribution

- The AUD1 framing, the Core Audio local-output controls, and the Android
  AudioTrack player are adapted from [gprot42/android-opendisplay at
  6f568c1](https://github.com/gprot42/android-opendisplay/tree/6f568c136e8b028accd2955855dd5817cd2c8eb6)
  under the [GNU GPL v3](LICENSE).
- The stereo converter and auxiliary ScreenCaptureKit stream in
  `Mac/AudioStream.swift` are adapted from
  [targetBridge at 7008853](https://github.com/swellweb/targetBridge/blob/7008853f5f177025d4296fe0334314f60cc1df38/TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift).
  The TargetBridge notice follows.

```text
MIT License

Copyright (c) 2026 Marco Caciotti

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
```
