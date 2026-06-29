<div align="center">
    <img src="./media/app_icon.png" alt="Flashbyte Logo" width="200" height="200"/>
    <h1>⚡ Flashbyte</h1>
    <h3>A Simple and fast local file sharing app.</h3>
</div>


### Seemless and smooth file sharing experience
- All file types supported!
- No file size limit!
- Does not use an external server (No internet required!!)
- Transfer files to any device on your local network.
- Open source & no data is collected!
- Made with [Flutter](https://flutter.dev/)!


### New in v2.0
- **TLS Encryption**: You can now send files over an encrypted connection.
- **Linux support**: Flashbyte now supports Linux.

### How does this work?
Flashbyte uses pure TCP sockets to establish a connection between two devices on a local network inside an isolate (isolated memory channel) which is then utilized to read and send over the file bytes whilst keeping the frontend (main UI isolate) smooth.

You can try out Flashbyte on the following platforms:

| Platform | Status                    | Download                                                                                     |
|----------|---------------------------|----------------------------------------------------------------------------------------------|
| Android  | Supported                 | [APK](https://github.com/iamsami101/Flashbyte/releases/download/v2.0.0/Flashbyte.2.0.0.apk) |
| Linux    | Supported                 | [AppImage](https://github.com/iamsami101/Flashbyte/releases/download/v2.0.0/Flashbyte.2.0.0.AppImage) |
| macOS    | Supported in v0.1.0 only | [DMG](https://github.com/iamsami101/Flashbyte/releases/download/v0.1.0/Flashbyte.0.1.0.dmg) |
| iOS      | In development            | N/A                                                                                          |
| Windows  | In development            | N/A                                                                                          |

If you find any bugs or issues or want to recommend any features, feel free to open an issue on github.
