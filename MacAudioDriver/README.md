# OpenDisplay audio driver for macOS

## Install and select an output

Use macOS 14 or later. In the Mac sender, open **Permissions → Audio Driver**
and choose **Install…** or **Update…**. Installer prompts for administrator
authorization. Restart when Installer asks, then launch the sender and
connect an audio-capable Android receiver.
The plug-in supports Apple silicon and Intel Macs.

The first Android ready for audio becomes the default output. Pick a
connected receiver in **System Settings → Sound → Output** or the Sound
control in Control Center. Its volume and mute controls apply to that
receiver. Choosing speakers or headphones keeps that selection until you
choose another output or finish the current group of sessions.

With a compatible Android receiver and driver, the Mac's volume and mute
adjust the Android system media stream, which can affect other Android
apps that use that stream. Control returns to the Mac's software gain or
mute if the receiver's system setting cannot be changed. Video works
without the driver.

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
`build/audio-driver`. Use `release` with a
`AUDIO_DRIVER_SIGNING_IDENTITY` (Developer ID Application), and a
`AUDIO_INSTALLER_SIGNING_IDENTITY` (Developer ID Installer). Notarize the
signed installer before public distribution.
The sender's Fastlane release lane embeds that signed and notarized package.
Release CI can import the Developer ID Installer identity using
`AUDIO_INSTALLER_CERTIFICATE_P12` (base64) and
`AUDIO_INSTALLER_CERTIFICATE_PASSWORD`.

For local Debug testing, `bash MacAudioDriver/build-package.sh debug build/audio-driver --reload-audio`
builds an installer that briefly restarts Core Audio after installation.

The app and driver use versioned HAL custom properties for the registry and
PCM. The sender presents a private, random lease token for registry changes
and PCM reads. The driver also checks the originating PID when HAL supplies
it. Each device has an independent bounded buffer, and a registry heartbeat
retires devices after the app stops responding.
