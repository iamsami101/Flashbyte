<div align="center">
    <img src="./media/app_icon.png" alt="Flashbyte Logo" width="200" height="200"/>
    <h1>⚡ Flashbyte</h1>
    <h3>A Simple and fast local file sharing app.</h3>
</div>


### Features
- **TLS Encryption**: You can send files over an encrypted connection.
- **Cross-platform support:** Flashbyte is supported on Android and Linux with more to come.
- **File sharing over local network:** You can send files over local network, without wifi access.
- **Lossless file sharing:** Send files in their original quality.
- **All file types supported:** Send file of any type.
- **No file size limit:** Send files no matter their size.
- **Doesn't use an external server:** Flashbytes sends to devices using your local network.
- **Cross-platform:** Transfer files to any device on your local network that has Flashbyte installed.
- **Open source & no data is collected:** All of the code is readily available on github.
- **Automatic Discovery:** Connect to users without having to manually type their IP.

### How does this work?
Flashbyte uses pure TCP sockets to establish a connection between two devices on a local network inside an isolate (isolated memory channel) which is then utilized to read and send over the file bytes whilst keeping the frontend (main UI isolate) smooth.

You can try out Flashbyte on the following platforms:

<!-- BEGIN AUTO RELEASE DOWNLOADS -->
| Platform | Download |
|----------|----------|
| Android | [APK](https://github.com/iamsami101/Flashbyte/releases/download/build-58eb8025ab95c6ded5220f09a6a1584cec2d9c0a/flashbyte-android.apk) \| [AAB](https://github.com/iamsami101/Flashbyte/releases/download/build-58eb8025ab95c6ded5220f09a6a1584cec2d9c0a/flashbyte-android.aab) |
| Linux | [Linux tarball](https://github.com/iamsami101/Flashbyte/releases/download/build-58eb8025ab95c6ded5220f09a6a1584cec2d9c0a/flashbyte-linux-x64.tar.gz) |
| macOS | [DMG installer](https://github.com/iamsami101/Flashbyte/releases/download/build-58eb8025ab95c6ded5220f09a6a1584cec2d9c0a/flashbyte-macos.dmg) |
| iOS | [Unsigned Runner.app zip](https://github.com/iamsami101/Flashbyte/releases/download/build-58eb8025ab95c6ded5220f09a6a1584cec2d9c0a/flashbyte-ios-unsigned-runner-app.zip) |
| Windows | [Windows zip](https://github.com/iamsami101/Flashbyte/releases/download/build-58eb8025ab95c6ded5220f09a6a1584cec2d9c0a/flashbyte-windows-x64.zip) |
<!-- END AUTO RELEASE DOWNLOADS -->

## Installation instructions:
- ### Android:
Install the Flashbyte `.apk` file from the [releases](https://github.com/iamsami101/Flashbyte/releases) page. Now, run the `.apk` file wether it is through a file explorer or via your browser's download page.

- ### Linux: 
#### Installation script (recommended): [](#tag)
You can install Flashbyte by running this in your linux terminal:
```bash
curl -fsSl "https://raw.githubusercontent.com/iamsami101/Flashbyte/refs/heads/main/install.sh" | bash
```
and if you want to uninstall it, you can run:
```bash
curl -fsSl "https://raw.githubusercontent.com/iamsami101/Flashbyte/refs/heads/main/uninstall.sh" | bash
```
---
#### Manual Installation

If you'd rather not run the install script, you can set up Flashbyte manually:

**1. Download the release**

Grab the latest `flashbyte-linux-x86_64.tar.gz` from the [Releases page](https://github.com/iamsami101/flashbyte/releases).

**2. Extract it**

```bash
mkdir -p ~/.local/share/flashbyte
tar xzf flashbyte-linux-x86_64.tar.gz -C ~/.local/share/flashbyte
chmod +x ~/.local/share/flashbyte/flashbyte
```

**3. Create a launcher script**

This makes sure the app can find its bundled libraries at runtime:

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/flashbyte << 'EOF'
#!/bin/bash
HERE="$HOME/.local/share/flashbyte"
export LD_LIBRARY_PATH="$HERE/lib:$LD_LIBRARY_PATH"
exec "$HERE/flashbyte" "$@"
EOF
chmod +x ~/.local/bin/flashbyte
```

Make sure `~/.local/bin` is on your `PATH`. Check with:

```bash
echo $PATH | grep -q "$HOME/.local/bin" && echo "OK" || echo "not on PATH"
```

If it's not, add this to your `~/.bashrc` or `~/.zshrc`, then restart your terminal:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**4. Install the icons**

```bash
for size_dir in ~/.local/share/flashbyte/share/icons/hicolor/*/apps; do
    size_name=$(basename "$(dirname "$size_dir")")
    mkdir -p ~/.local/share/icons/hicolor/"$size_name"/apps
    cp "$size_dir/flashbyte.png" ~/.local/share/icons/hicolor/"$size_name"/apps/flashbyte.png
done
```

**5. Install the desktop entry**

```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/flashbyte.desktop << EOF
[Desktop Entry]
Type=Application
Name=Flashbyte
Comment=LAN file sharing app
Exec=$HOME/.local/bin/flashbyte
Icon=flashbyte
Categories=Network;
Terminal=false
StartupWMClass=flashbyte
EOF
chmod +x ~/.local/share/applications/flashbyte.desktop
```

**6. Refresh your desktop caches**

```bash
update-desktop-database ~/.local/share/applications
gtk-update-icon-cache ~/.local/share/icons/hicolor
```

**7. Run it**

Either launch **Flashbyte** from your application menu, or run it directly:

```bash
flashbyte
```

#### Uninstalling manually

```bash
rm -rf ~/.local/share/flashbyte
rm -f ~/.local/bin/flashbyte
rm -f ~/.local/share/applications/flashbyte.desktop
rm -f ~/.local/share/icons/hicolor/*/apps/flashbyte.png
update-desktop-database ~/.local/share/applications
gtk-update-icon-cache ~/.local/share/icons/hicolor
```

- ### Windows:
Download `flashbyte-windows-x64.zip` from the [releases](https://github.com/iamsami101/Flashbyte/releases) page.

Extract the zip file, then run:

```powershell
flashbyte.exe
```

If Windows SmartScreen warns you that the app is from an unknown publisher, choose **More info** and then **Run anyway**. To remove Flashbyte, delete the extracted folder.

- ### macOS:
Download `flashbyte-macos.dmg` from the [releases](https://github.com/iamsami101/Flashbyte/releases) page.

Open the DMG, drag **flashbyte.app** into **Applications**, then launch it from Applications.

If macOS blocks the app because it is not signed/notarized yet, open **System Settings > Privacy & Security** and allow Flashbyte, or right-click the app and choose **Open**.

- ### iOS:
The current iOS release artifact is an unsigned `Runner.app` zip. It is useful for CI output and local signing, but it cannot be installed on normal iPhones directly.

To install on a device, build/sign from source with an Apple Developer account:

```bash
flutter build ipa --release
```

Then distribute the signed `.ipa` through TestFlight, Apple Configurator, or your own MDM/internal distribution setup.

## Signing release builds

The GitHub workflow builds release artifacts and packages macOS as a DMG, but platform signing requires private certificates and provisioning files that should be stored as GitHub Actions secrets.

To sign Android releases, add an upload keystore and configure Gradle signing with secrets such as `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`.

To sign and notarize macOS releases, use an Apple Developer ID Application certificate plus notarization credentials, commonly stored as `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`, `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`.

To create an installable iOS release, add an Apple Distribution certificate and provisioning profile, commonly stored as `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`, `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, and `APPLE_TEAM_ID`.

To sign Windows releases, use a Windows code-signing certificate with `signtool`, commonly stored as `WINDOWS_CERTIFICATE_BASE64` and `WINDOWS_CERTIFICATE_PASSWORD`.

## Building from Source

If you'd like to build Flashbyte yourself instead of using a prebuilt release, you'll need Flutter installed and set up for the platform(s) you're targeting.

### Prerequisites

- **Flutter SDK** (stable channel) — [install instructions](https://docs.flutter.dev/get-started/install)
- **Git**

Verify your setup once Flutter is installed:

```bash
flutter doctor
```

Resolve any issues it flags before continuing (missing Android SDK, missing Linux toolchain, etc. — covered per-platform below).

### Clone the repository

```bash
git clone https://github.com/iamsami101/flashbyte.git
cd flashbyte
flutter pub get
```

---

### Building for Linux

**Additional prerequisites:**

```bash
sudo apt update
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
```

Enable Linux desktop support if you haven't already:

```bash
flutter config --enable-linux-desktop
```

Build a release binary:

```bash
flutter build linux --release
```

The output bundle will be in:

```bash
build/linux/x64/release/bundle/
```

This `bundle/` folder is exactly what gets packaged into the `.tar.gz` release — it contains `data/`, `lib/`, the `flashbyte` executable, and `share/` with icons and the desktop file. You can run it directly:

```bash
cd build/linux/x64/release/bundle
./flashbyte
```

Or follow the [Manual Installation](#manual-installation) steps above, using this `bundle/` folder as your source instead of a downloaded release.

---

### Building for Android

**Additional prerequisites:**

- Android SDK (via [Android Studio](https://developer.android.com/studio) or command-line tools)
- A configured `ANDROID_HOME` environment variable
- At least one accepted Android SDK license:

```bash
flutter doctor --android-licenses
```

Build a release APK:

```bash
flutter build apk --release
```

The output will be at:

```bash
build/app/outputs/flutter-apk/app-release.apk
```

Install it on a connected device or emulator:

```bash
flutter install
```

Or manually transfer the APK to your device and install it (you'll need "Install from unknown sources" enabled, since this isn't distributed via the Play Store).

If you want a split APK per architecture (smaller file size):

```bash
flutter build apk --split-per-abi --release
```

This produces separate APKs in the same output folder, one per ABI (`armeabi-v7a`, `arm64-v8a`, `x86_64`).

---

### Debug builds

For development/testing rather than a release build, drop `--release` and just run:

```bash
flutter run
```

Flutter will detect any connected device (or ask you to choose one) and hot-reload as you make changes.
