#!/bin/bash
set -e

# ---- Must match install.sh ----
APP_NAME="flashbyte"
APP_DISPLAY_NAME="Flashbyte"
# --------------------------------

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
echo "Uninstalling $APP_DISPLAY_NAME..."
echo ""

REMOVED_ANYTHING=false

# 1. Remove the app bundle
if [ -d "$APP_DIR" ]; then
    rm -rf "$APP_DIR"
    echo "Removed: $APP_DIR"
    REMOVED_ANYTHING=true
fi

# 2. Remove the launcher script
if [ -f "$BIN_DIR/$APP_NAME" ]; then
    rm -f "$BIN_DIR/$APP_NAME"
    echo "Removed: $BIN_DIR/$APP_NAME"
    REMOVED_ANYTHING=true
fi

# 3. Remove the desktop file
if [ -f "$DESKTOP_DIR/$APP_NAME.desktop" ]; then
    rm -f "$DESKTOP_DIR/$APP_NAME.desktop"
    echo "Removed: $DESKTOP_DIR/$APP_NAME.desktop"
    REMOVED_ANYTHING=true
fi

# 4. Remove all installed icon sizes
for icon_file in "$ICON_BASE_DIR"/*/apps/"$APP_NAME.png"; do
    [ -f "$icon_file" ] || continue
    rm -f "$icon_file"
    echo "Removed: $icon_file"
    REMOVED_ANYTHING=true
done

# 5. Refresh caches
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache "$ICON_BASE_DIR" 2>/dev/null || true

echo ""
if [ "$REMOVED_ANYTHING" = true ]; then
    echo "$APP_DISPLAY_NAME has been uninstalled."
else
    echo "$APP_DISPLAY_NAME doesn't appear to be installed. Nothing to do."
fi