#!/bin/bash
set -e

GITHUB_REPO="iamsami101/flashbyte"
APP_NAME="flashbyte"
APP_DISPLAY_NAME="Flashbyte"

APP_DIR="$HOME/.local/share/$APP_NAME"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_BASE_DIR="$HOME/.local/share/icons/hicolor"

# ---- Banner ----
print_banner() {
    LOGO=(
    '      ████████████████'
    '      ██            ██'
    '    ██            ██  '
    '    ██          ██    '
    '  ██          ██      '
    '  ██        ████████  '
    '██                ██  '
    '████████        ██    '
    '      ██      ██      '
    '    ██      ██        '
    '    ██    ██          '
    '  ██    ██            '
    '  ██  ██              '
    '██  ██                '
    '████                  '
    )

    TEXT=(
    '░██████████░██                       ░██        ░██                      ░██               '
    '░██        ░██                       ░██        ░██                      ░██               '
    '░██        ░██  ░██████    ░███████  ░████████  ░████████  ░██    ░██ ░████████  ░███████  '
    '░█████████ ░██       ░██  ░██        ░██    ░██ ░██    ░██ ░██    ░██    ░██    ░██    ░██ '
    '░██        ░██  ░███████   ░███████  ░██    ░██ ░██    ░██ ░██    ░██    ░██    ░█████████ '
    '░██        ░██ ░██   ░██         ░██ ░██    ░██ ░███   ░██ ░██   ░███    ░██    ░██        '
    '░██        ░██  ░█████░██  ░███████  ░██    ░██ ░██░█████   ░█████░██     ░████  ░███████  '
    '                                                                  ░██                      '
    '                                                            ░███████                       '
    )

    logo_lines=${#LOGO[@]}
    text_lines=${#TEXT[@]}
    max_lines=$(( logo_lines > text_lines ? logo_lines : text_lines ))
    logo_pad_top=$(( (max_lines - logo_lines) / 2 ))
    text_pad_top=$(( (max_lines - text_lines) / 2 ))

    logo_width=0
    for line in "${LOGO[@]}"; do
        len=${#line}
        (( len > logo_width )) && logo_width=$len
    done

    GAP="   "

    for (( i=0; i<max_lines; i++ )); do
        logo_idx=$(( i - logo_pad_top ))
        text_idx=$(( i - text_pad_top ))
        logo_part=""
        text_part=""
        (( logo_idx >= 0 && logo_idx < logo_lines )) && logo_part="${LOGO[$logo_idx]}"
        (( text_idx >= 0 && text_idx < text_lines )) && text_part="${TEXT[$text_idx]}"
        printf "%-${logo_width}s%s%s\n" "$logo_part" "$GAP" "$text_part"
    done
}

print_banner
echo ""
echo "Installing $APP_DISPLAY_NAME..."

# 1. Check dependencies
for cmd in curl jq tar; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' is required but not installed. Install it with: sudo apt install $cmd"
        exit 1
    fi
done

# 2. Get the latest release download URL from GitHub API
echo "Checking latest release..."
API_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
DOWNLOAD_URL=$(curl -fsSL "$API_URL" | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')

if [ -z "$DOWNLOAD_URL" ]; then
    echo "Error: could not find a .tar.gz asset in the latest release."
    exit 1
fi

echo "Found: $DOWNLOAD_URL"

# 3. Download and extract
mkdir -p "$APP_DIR" "$BIN_DIR" "$DESKTOP_DIR"
TMP_TARBALL=$(mktemp)
echo "Downloading $APP_DISPLAY_NAME..."
curl -fsSL "$DOWNLOAD_URL" -o "$TMP_TARBALL"

echo "Extracting..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
tar xzf "$TMP_TARBALL" -C "$APP_DIR"
rm -f "$TMP_TARBALL"

chmod +x "$APP_DIR/$APP_NAME"

# 4. Create a launcher script on PATH
cat > "$BIN_DIR/$APP_NAME" << LAUNCHER_EOF
#!/bin/bash
HERE="$APP_DIR"
export LD_LIBRARY_PATH="\$HERE/lib:\$LD_LIBRARY_PATH"
exec "\$HERE/$APP_NAME" "\$@"
LAUNCHER_EOF
chmod +x "$BIN_DIR/$APP_NAME"

# 5. Install all icon sizes bundled in share/icons/hicolor
if [ -d "$APP_DIR/share/icons/hicolor" ]; then
    for size_dir in "$APP_DIR"/share/icons/hicolor/*/apps; do
        [ -d "$size_dir" ] || continue
        size_name=$(basename "$(dirname "$size_dir")")
        mkdir -p "$ICON_BASE_DIR/$size_name/apps"
        cp "$size_dir/$APP_NAME.png" "$ICON_BASE_DIR/$size_name/apps/$APP_NAME.png" 2>/dev/null || true
    done
else
    echo "Warning: no icons found in bundle, skipping icon install."
fi

# 6. Create the .desktop file, pointing at the launcher (not the raw binary)
cat > "$DESKTOP_DIR/$APP_NAME.desktop" << DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=$APP_DISPLAY_NAME
Comment=LAN file sharing app
Exec=$BIN_DIR/$APP_NAME
Icon=$APP_NAME
Categories=Network;
Terminal=false
StartupWMClass=$APP_NAME
DESKTOP_EOF
chmod +x "$DESKTOP_DIR/$APP_NAME.desktop"

# 7. Refresh caches
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache "$ICON_BASE_DIR" 2>/dev/null || true

echo ""
echo "$APP_DISPLAY_NAME installed successfully."

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    echo "Note: $BIN_DIR is not on your PATH."
    echo "Add this to your ~/.bashrc or ~/.zshrc to run '$APP_NAME' from anywhere:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "You can now find it in your application menu, or run it directly:"
echo "  $BIN_DIR/$APP_NAME"