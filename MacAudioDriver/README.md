# OpenDisplay audio driver for macOS

## Install and select an output

Use macOS 14 or later. Install **OpenDisplay Audio.pkg** for the release
Mac sender or **OpenDisplay Audio Dev.pkg** for the Debug sender. macOS
prompts for administrator authorization. Restart when Installer asks, then
launch the matching sender and connect an audio-capable Android receiver.
The plug-in supports Apple silicon and Intel Macs.

The first Android ready for audio becomes the default output. Pick a
connected receiver in **System Settings → Sound → Output** or the Sound
control in Control Center. Its volume and mute controls apply to that
receiver. Choosing speakers or headphones keeps that selection until you
choose another output or finish the current group of sessions.

If the selected Android disconnects, OpenDisplay selects the earliest
remaining Android ready for audio, or restores the prior local output
when no receiver remains. If the Mac sender is killed, the driver retires
its outputs when the process lease expires and macOS selects an available
output. If the session asks you to install or update the driver, make sure
its Debug or release variant matches the Mac sender.

## Uninstall

Quit the Mac sender. In Finder, use **Go → Go to Folder** and open
`/Library/Audio/Plug-Ins/HAL`. Move the matching **OpenDisplay Audio.driver**
or **OpenDisplay Audio Dev.driver** bundle to the Trash with administrator
authorization, then restart.

## Build and verify

From the checkout, run `bash MacAudioDriver/test.sh` for the driver tests and
`bash MacAudioDriver/build-package.sh debug` for a local Debug installer in
`build/audio-driver`. Use `release` with the sender's `DEVELOPMENT_TEAM`, a
`AUDIO_DRIVER_SIGNING_IDENTITY` (Developer ID Application), and a
`AUDIO_INSTALLER_SIGNING_IDENTITY` (Developer ID Installer). Notarize the
signed installer before public distribution.

The app and driver use versioned HAL custom properties for the registry and
PCM. Only the app that owns the registry can drain its audio. Each device
has an independent bounded buffer, and a registry heartbeat retires devices
after the app stops responding. The macOS release driver checks the
publisher's bundle identity and signing team. The ad-hoc Debug driver
accepts the separate Debug sender identity for local development.
