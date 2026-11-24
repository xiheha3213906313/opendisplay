# Android GitHub release key

This directory is the signing identity for the GitHub release APK. The
keystore, its passwords, and the key alias are committed so a later build
signs with the same key when the `ANDROID_KEYSTORE_*` Actions secrets are
unset. Actions secrets still take precedence when they are set.

Anyone who can read the repository can sign APKs with this key. An install
signed with a different key cannot be updated in place; the old app has to
be uninstalled first.

`sign-release-apk.sh` reads the password files and does not print them.
