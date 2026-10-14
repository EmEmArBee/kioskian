#!/usr/bin/env bash
#
# kiosk-setup.sh - Debian minimal browser-kiosk installer (hotel business centers)
# Version 2.0
#
# Run on a FRESH Debian 12/13 netinst install (no desktop environment selected):
#   wget -O kiosk-setup.sh https://raw.githubusercontent.com/<you>/<repo>/main/kiosk-setup.sh
#   sudo bash kiosk-setup.sh          (or:  su -   then   bash kiosk-setup.sh)
#
# Stack: Xorg + Openbox (no desktop environment) + Chromium or Firefox ESR.
# The script is interactive and can be re-run safely (it overwrites its own files).
#
set -Eeuo pipefail

# "su" without the dash keeps the user's PATH, which lacks /usr/sbin (usermod, locale-gen, ...)
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

SCRIPT_VERSION="2.0"
LOG_FILE="/var/log/kiosk-setup.log"
CONF_DIR="/etc/kiosk"
LIB_DIR="/usr/local/lib/kiosk"
CHROMIUM_POLICY_DIR="/etc/chromium/policies/managed"

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'warn "Error on line $LINENO (command: $BASH_COMMAND). Details: $LOG_FILE"' ERR

# ----------------------------------------------------------------------------
# Interactive helpers (prompts go to /dev/tty so they work even when logged)
# ----------------------------------------------------------------------------
ask() { # ask "Prompt" "default"  -> prints the answer
    local prompt="$1" def="${2:-}" a=""
    if [ -n "$def" ]; then
        printf '%s [%s]: ' "$prompt" "$def" >/dev/tty
    else
        printf '%s: ' "$prompt" >/dev/tty
    fi
    IFS= read -r a </dev/tty || a=""
    printf '%s' "${a:-$def}"
}

ask_yn() { # ask_yn "Prompt" Y|N  -> exit status 0 = yes
    local prompt="$1" def="${2:-Y}" a hint
    if [ "$def" = "Y" ]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        printf '%s [%s]: ' "$prompt" "$hint" >/dev/tty
        IFS= read -r a </dev/tty || a=""
        a="${a:-$def}"
        case "${a,,}" in
            y|yes|s|si|sì) return 0 ;;
            n|no) return 1 ;;
        esac
        echo "Please answer y or n." >/dev/tty
    done
}

choose() { # choose "Title" default_number item1 item2 ...  -> prints chosen item
    local title="$1" def="$2" a i
    shift 2
    local items=("$@")
    {
        echo "$title"
        for i in "${!items[@]}"; do
            printf '  %d) %s\n' "$((i + 1))" "${items[$i]}"
        done
    } >/dev/tty
    while true; do
        printf 'Choice [%s]: ' "$def" >/dev/tty
        IFS= read -r a </dev/tty || a=""
        a="${a:-$def}"
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#items[@]}" ]; then
            printf '%s' "${items[$((a - 1))]}"
            return 0
        fi
        echo "Invalid choice." >/dev/tty
    done
}

valid_url() {
    case "$1" in http://?*|https://?*) ;; *) return 1 ;; esac
    case "$1" in *[[:space:]\"\'\`\$\\]*) return 1 ;; esac
    return 0
}

valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }
valid_hostname() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1 && [ -f "$0" ]; then
            exec sudo -E bash "$0" "$@"
        fi
        die "Run this script as root (sudo bash $0  /  su - then bash $0)."
    fi
}

setup_logging() {
    : >>"$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

check_system() {
    [ -r /etc/os-release ] || die "Cannot read /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "debian" ] || die "This script is for Debian (found: ${ID:-unknown})."
    if [ "${VERSION_ID:-0}" -lt 12 ] 2>/dev/null; then
        warn "Tested on Debian 12/13. Found version ${VERSION_ID:-unknown}: continue at your own risk."
    fi
    [ "$(dpkg --print-architecture)" = "amd64" ] || warn "Architecture is not amd64: untested."
    if ! ping -c1 -W3 deb.debian.org >/dev/null 2>&1; then
        warn "Cannot reach deb.debian.org by ping (ICMP may just be blocked). apt will tell us."
    fi
}

# ----------------------------------------------------------------------------
# Questions
# ----------------------------------------------------------------------------
collect_answers() {
    say "Kiosk setup v$SCRIPT_VERSION - a few questions"

    while true; do
        KIOSK_USER="$(ask "Name of the (passwordless) kiosk user" "kiosk")"
        if ! valid_username "$KIOSK_USER"; then echo "Invalid user name." >/dev/tty; continue; fi
        if [ "$KIOSK_USER" = "root" ] || [ "$KIOSK_USER" = "${SUDO_USER:-}" ]; then
            echo "Pick a dedicated user, not root or your admin account." >/dev/tty; continue
        fi
        if id "$KIOSK_USER" >/dev/null 2>&1; then
            if [ "$(id -u "$KIOSK_USER")" -lt 1000 ]; then
                echo "That is a system account: pick another name." >/dev/tty; continue
            fi
            {
                echo "User '$KIOSK_USER' already exists. It will be reconfigured as the passwordless guest"
                echo "account (password locked, sudo removed). If it is the administrator account you"
                echo "created during the Debian installation, answer N and pick another name."
            } >/dev/tty
            ask_yn "Reconfigure '$KIOSK_USER' as the kiosk guest account?" N || continue
        fi
        break
    done

    local b
    b="$(choose "Which browser?" 1 "Chromium" "Firefox ESR")"
    if [ "$b" = "Chromium" ]; then BROWSER="chromium"; else BROWSER="firefox-esr"; fi

    while true; do
        START_URL="$(ask "Start page" "https://www.google.com")"
        case "$START_URL" in http://*|https://*) ;; *) START_URL="https://$START_URL" ;; esac
        valid_url "$START_URL" && break
        echo "Invalid URL (no spaces or quotes)." >/dev/tty
    done

    while true; do
        IDLE_MINUTES="$(ask "Inactivity timeout before the session is reset (minutes)" "15")"
        [[ "$IDLE_MINUTES" =~ ^[0-9]+$ ]] && [ "$IDLE_MINUTES" -ge 1 ] && [ "$IDLE_MINUTES" -le 240 ] && break
        echo "Enter a number between 1 and 240." >/dev/tty
    done

    while true; do
        NEW_HOSTNAME="$(ask "Hostname of this machine" "$(hostname)")"
        valid_hostname "$NEW_HOSTNAME" && break
        echo "Invalid hostname." >/dev/tty
    done

    if ask_yn "Make USB storage read-only for guests?" Y; then USB_RO=1; else USB_RO=0; fi

    WANT_CUPS=0; ALL_DRIVERS=0
    if ask_yn "Install printing support (CUPS)?" Y; then
        WANT_CUPS=1
        if ask_yn "  Also install ALL printer drivers (large; most network printers don't need it)?" N; then ALL_DRIVERS=1; fi
    fi

    if ask_yn "Install audio (PipeWire)?" Y; then WANT_AUDIO=1; else WANT_AUDIO=0; fi
    if ask_yn "Install extra fonts for international websites (Asian/Arabic/Indic/emoji, ~200 MB)?" Y; then WANT_FONTS=1; else WANT_FONTS=0; fi

    WANT_SSH=0; ADMIN_USER=""; ADMIN_PUBKEY=""; CREATE_ADMIN=0
    if ask_yn "Enable remote administration over SSH?" Y; then
        WANT_SSH=1
        local def_admin="${SUDO_USER:-}"
        if [ -z "$def_admin" ]; then
            def_admin="$(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1; exit}')"
        fi
        while true; do
            ADMIN_USER="$(ask "  Admin user allowed to log in via SSH" "$def_admin")"
            valid_username "$ADMIN_USER" || { echo "Invalid user name." >/dev/tty; continue; }
            [ "$ADMIN_USER" != "$KIOSK_USER" ] || { echo "Must differ from the kiosk user." >/dev/tty; continue; }
            if ! id "$ADMIN_USER" >/dev/null 2>&1; then
                if ask_yn "  User '$ADMIN_USER' does not exist. Create it now?" Y; then CREATE_ADMIN=1; else continue; fi
            fi
            break
        done
        while true; do
            ADMIN_PUBKEY="$(ask "  Paste the admin's SSH PUBLIC key (Enter = keep password login)" "")"
            [ -z "$ADMIN_PUBKEY" ] && break
            if ssh-keygen -l -f /dev/stdin <<<"$ADMIN_PUBKEY" >/dev/null 2>&1; then break; fi
            echo "That does not look like a valid public key (should start with ssh-ed25519 / ssh-rsa ...)." >/dev/tty
        done
    fi

    WIFI_SSID=""; WIFI_PSK=""
    if ask_yn "Preconfigure a Wi-Fi network (Ethernet/DHCP works anyway)?" N; then
        while true; do
            WIFI_SSID="$(ask "  Wi-Fi name (SSID)" "")"
            if [ -z "$WIFI_SSID" ] || [ "${#WIFI_SSID}" -gt 32 ]; then echo "SSID must be 1-32 characters." >/dev/tty; continue; fi
            case "$WIFI_SSID" in *\;*|*\\*) echo "SSIDs with ; or \\ are not supported here: set it later with nmtui." >/dev/tty; WIFI_SSID=""; break ;; esac
            printf '  Wi-Fi password (Enter = open network): ' >/dev/tty
            IFS= read -rs WIFI_PSK </dev/tty || WIFI_PSK=""
            echo >/dev/tty
            if [ -n "$WIFI_PSK" ] && { [ "${#WIFI_PSK}" -lt 8 ] || [ "${#WIFI_PSK}" -gt 63 ]; }; then
                echo "WPA password must be 8-63 characters." >/dev/tty; continue
            fi
            break
        done
    fi

    if ask_yn "Remove unused languages/man pages to save space?" Y; then SLIM=1; else SLIM=0; fi
    if ask_yn "Optimize boot (hidden GRUB, no wait-online, quiet boot)?" Y; then BOOTOPT=1; else BOOTOPT=0; fi
    if ask_yn "Reboot automatically when finished?" Y; then DO_REBOOT=1; else DO_REBOOT=0; fi
}

confirm_answers() {
    cat >/dev/tty <<EOF

---------------- Summary ----------------
 Kiosk user .......... $KIOSK_USER (no password, autologin on tty1)
 Browser ............. $BROWSER
 Start page .......... $START_URL
 Idle reset .......... $IDLE_MINUTES min
 Hostname ............ $NEW_HOSTNAME
 USB read-only ....... $([ "$USB_RO" = 1 ] && echo yes || echo no)
 Printing (CUPS) ..... $([ "$WANT_CUPS" = 1 ] && echo yes || echo no)$([ "$ALL_DRIVERS" = 1 ] && echo " + all drivers")
 Audio ............... $([ "$WANT_AUDIO" = 1 ] && echo yes || echo no)
 Extra fonts ......... $([ "$WANT_FONTS" = 1 ] && echo yes || echo no)
 SSH ................. $([ "$WANT_SSH" = 1 ] && echo "yes, admin '$ADMIN_USER' ($([ -n "$ADMIN_PUBKEY" ] && echo "key only" || echo "password allowed"))" || echo no)
 Wi-Fi preset ........ $([ -n "$WIFI_SSID" ] && echo "$WIFI_SSID" || echo none)
 Keyboard / language . Italian keyboard, English system (locked)
 Updates ............. security only, nightly reboot at 02:00
-----------------------------------------
EOF
    ask_yn "Proceed with the installation?" Y || die "Aborted by user."
}

# ----------------------------------------------------------------------------
# APT
# ----------------------------------------------------------------------------
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" --no-install-recommends "$@"; }

apt_try() { # optional packages: one by one, never fatal
    local p
    for p in "$@"; do
        if DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" --no-install-recommends "$p" >/dev/null 2>&1; then
            echo "  ok: $p"
        else
            warn "optional package not installed: $p"
        fi
    done
}

enable_nonfree_firmware() { # optional args (for testing): sources.list  sources.list.d
    local list="${1:-/etc/apt/sources.list}" dir="${2:-/etc/apt/sources.list.d}" f
    if [ -f "$list" ]; then
        sed -i -E 's/^(deb(-src)?[[:space:]]+cdrom:)/# \1/' "$list"
        sed -i -E '/^deb(-src)?[[:space:]]+[^#]/{/non-free-firmware/b;s/$/ non-free-firmware/}' "$list"
    fi
    if [ -d "$dir" ]; then
        for f in "$dir"/*.sources; do
            [ -e "$f" ] || continue
            sed -i -E '/^Components:/{/non-free-firmware/b;s/$/ non-free-firmware/}' "$f"
        done
    fi
}

step_apt() {
    say "Enabling non-free-firmware and updating the system"
    enable_nonfree_firmware
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade "${APT_OPTS[@]}"
}

step_packages() {
    say "Installing packages"
    apt_install \
        ca-certificates cron locales console-setup keyboard-configuration systemd-timesyncd \
        xserver-xorg xserver-xorg-legacy xinit x11-xserver-utils x11-xkb-utils xprintidle \
        libgl1-mesa-dri dbus-x11 dbus-user-session libpam-systemd \
        openbox pcmanfm xdg-utils adwaita-icon-theme udisks2 gvfs gvfs-backends \
        fonts-liberation fonts-dejavu-core unattended-upgrades

    say "Installing firmware (best effort: hardware varies)"
    apt_try firmware-linux firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 \
        firmware-misc-nonfree firmware-amd-graphics firmware-sof-signed intel-microcode amd64-microcode

    say "Installing the browser ($BROWSER)"
    if [ "$BROWSER" = "chromium" ]; then
        apt_install chromium
    else
        local p="" c
        for c in firefox-esr firefox; do
            if apt-cache show "$c" >/dev/null 2>&1; then p="$c"; break; fi
        done
        [ -n "$p" ] || die "No Firefox package found in the configured repositories."
        apt_install "$p"
        BROWSER="$p"
    fi

    [ "$WANT_FONTS" = 1 ] && apt_try fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
    if [ "$WANT_AUDIO" = 1 ]; then
        apt_install pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils
        systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 || true
    fi
    if [ "$WANT_CUPS" = 1 ]; then
        apt_install cups cups-filters
        [ "$ALL_DRIVERS" = 1 ] && apt_try printer-driver-all
        # cups-browsed auto-discovers remote printers: not wanted on a guest network
        systemctl disable --now cups-browsed.service >/dev/null 2>&1 || true
        systemctl mask cups-browsed.service >/dev/null 2>&1 || true
    fi
    return 0
}

# ----------------------------------------------------------------------------
# User, locale, keyboard
# ----------------------------------------------------------------------------
step_user() {
    say "Creating the kiosk user ($KIOSK_USER)"
    if id "$KIOSK_USER" >/dev/null 2>&1; then
        warn "User $KIOSK_USER already exists: reusing it."
        if id -nG "$KIOSK_USER" | tr ' ' '\n' | grep -qx sudo; then
            warn "$KIOSK_USER is in the sudo group! Removing it."
            gpasswd -d "$KIOSK_USER" sudo >/dev/null || true
        fi
    else
        useradd --create-home --shell /bin/bash --comment "Kiosk guest" "$KIOSK_USER"
    fi
    passwd -l "$KIOSK_USER" >/dev/null
    usermod -aG audio,video "$KIOSK_USER"
    KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
    chmod 750 "$KIOSK_HOME"
}

step_locale_keyboard() {
    say "Locking language (English) and keyboard (Italian)"
    sed -i -E 's/^#[[:space:]]*(en_US\.UTF-8 UTF-8)/\1/' /etc/locale.gen
    grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >>/etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en

    cat >/etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="it"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    install -d /etc/X11/xorg.conf.d
    cat >/etc/X11/xorg.conf.d/00-kiosk-keyboard.conf <<'EOF'
Section "InputClass"
    Identifier "kiosk keyboard"
    MatchIsKeyboard "on"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "it"
    Option "XkbVariant" ""
    Option "XkbOptions" ""
EndSection
EOF
    setupcon --save >/dev/null 2>&1 || true
}

step_hostname() {
    if [ "$NEW_HOSTNAME" != "$(hostname)" ]; then
        say "Setting hostname to $NEW_HOSTNAME"
        hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || echo "$NEW_HOSTNAME" >/etc/hostname
        if grep -q '^127\.0\.1\.1' /etc/hosts; then
            sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
        else
            printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >>/etc/hosts
        fi
    fi
}

# ----------------------------------------------------------------------------
# Kiosk session files
# ----------------------------------------------------------------------------
write_session_files() {
    install -d -m 755 "$CONF_DIR" "$LIB_DIR"

    cat >"$CONF_DIR/kiosk.conf" <<EOF
# Kiosk configuration. After editing run:  sudo kiosk-restart-session
KIOSK_USER="$KIOSK_USER"
BROWSER="$BROWSER"
START_URL="$START_URL"
IDLE_MINUTES=$IDLE_MINUTES
EOF
    chmod 644 "$CONF_DIR/kiosk.conf"

    # --- wipe: remove everything a guest may have left behind -------------
    cat >"$LIB_DIR/wipe.sh" <<'EOF'
#!/bin/bash
# Runs as the kiosk user at the start of every session.
[ -n "${HOME:-}" ] && [ "$HOME" != "/" ] || exit 1
for d in Downloads Documents Desktop Music Pictures Videos Public Templates tmp .temp .cache \
         .local/share/Trash .local/share/recently-used.xbel .config/chromium .config/pcmanfm \
         .config/libfm .config/gtk-3.0 .mozilla .cache/mozilla; do
    rm -rf -- "${HOME:?}/$d"
done
mkdir -p "$HOME/Downloads"
find /tmp -mindepth 1 -maxdepth 1 -user "$(id -un)" ! -name '.X*' ! -name '.ICE*' \
     -exec rm -rf -- {} + 2>/dev/null
exit 0
EOF

    # --- idle watcher: ends the session after N idle minutes ---------------
    cat >"$LIB_DIR/idle-watcher.sh" <<'EOF'
#!/bin/bash
# Ends the X session after IDLE_MINUTES without keyboard/mouse input.
# The login is then re-created automatically (getty autologin) and wipe.sh runs.
. /etc/kiosk/kiosk.conf
limit_ms=$((IDLE_MINUTES * 60 * 1000))
while sleep 15; do
    idle="$(xprintidle 2>/dev/null)" || continue
    if [ "$idle" -ge "$limit_ms" ]; then
        openbox --exit
        exit 0
    fi
done
EOF

    # --- session: what runs inside X --------------------------------------
    cat >"$LIB_DIR/session.sh" <<'EOF'
#!/bin/bash
# X session of the kiosk user (started by /etc/profile.d/kiosk-autostart.sh).
. /etc/kiosk/kiosk.conf
LIB=/usr/local/lib/kiosk
export LANG=en_US.UTF-8 LANGUAGE=en_US:en

"$LIB/wipe.sh"

xset s off
xset -dpms
xset s noblank
setxkbmap -layout it -option ""
xsetroot -solid black

launch_browser() {
    case "$BROWSER" in
        chromium)
            chromium --lang=en-US --start-maximized --incognito --no-first-run --noerrdialogs \
                --disable-infobars --disable-session-crashed-bubble --password-store=basic \
                --disable-features=Translate "$START_URL" ;;
        *)
            "$BROWSER" --private-window "$START_URL" ;;
    esac
}

openbox --config-file "$LIB/openbox-rc.xml" &
OB_PID=$!
trap 'kill $(jobs -p) 2>/dev/null' EXIT
sleep 1

# Browser: relaunch if it is closed or crashes
(
    while kill -0 "$OB_PID" 2>/dev/null; do
        launch_browser
        sleep 2
    done
) &

"$LIB/idle-watcher.sh" &

wait "$OB_PID"
EOF

    # --- openbox: no menus/keybindings, browser maximized, file manager floating
    cat >"$LIB_DIR/openbox-rc.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse></focus>
  <placement><policy>Smart</policy></placement>
  <theme><name>Clearlooks</name><titleLayout>NLC</titleLayout><keepBorder>no</keepBorder></theme>
  <desktops><number>1</number></desktops>
  <keyboard>
    <keybind key="A-Tab"><action name="NextWindow"/></keybind>
  </keyboard>
  <mouse>
    <context name="Frame">
      <mousebind button="A-Left" action="Press"><action name="Focus"/><action name="Raise"/></mousebind>
    </context>
    <context name="Titlebar">
      <mousebind button="Left" action="Press"><action name="Focus"/><action name="Raise"/></mousebind>
      <mousebind button="Left" action="Drag"><action name="Move"/></mousebind>
    </context>
    <context name="Close">
      <mousebind button="Left" action="Click"><action name="Close"/></mousebind>
    </context>
    <context name="Client">
      <mousebind button="Left" action="Press"><action name="Focus"/><action name="Raise"/></mousebind>
    </context>
  </mouse>
  <applications>
    <application class="Chromium"><decor>no</decor><maximized>yes</maximized></application>
    <application class="chromium"><decor>no</decor><maximized>yes</maximized></application>
    <application class="firefox-esr"><decor>no</decor><maximized>yes</maximized></application>
    <application class="Firefox-esr"><decor>no</decor><maximized>yes</maximized></application>
    <application class="firefox"><decor>no</decor><maximized>yes</maximized></application>
    <application class="Firefox"><decor>no</decor><maximized>yes</maximized></application>
    <application class="Pcmanfm">
      <size><width>80%</width><height>80%</height></size>
      <position force="no"><x>center</x><y>center</y></position>
    </application>
    <application class="pcmanfm">
      <size><width>80%</width><height>80%</height></size>
      <position force="no"><x>center</x><y>center</y></position>
    </application>
  </applications>
</openbox_config>
EOF

    chmod 755 "$LIB_DIR"/wipe.sh "$LIB_DIR"/idle-watcher.sh "$LIB_DIR"/session.sh
    chmod 644 "$LIB_DIR"/openbox-rc.xml
    chown -R root:root "$LIB_DIR" "$CONF_DIR"
}

write_admin_helpers() {
    cat >/usr/local/sbin/kiosk-restart-session <<'EOF'
#!/bin/bash
# Ends the kiosk session; autologin starts a fresh one (re-reads /etc/kiosk/kiosk.conf).
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
. /etc/kiosk/kiosk.conf
exec loginctl terminate-user "$KIOSK_USER"
EOF
    cat >/usr/local/sbin/kiosk-set-url <<'EOF'
#!/bin/bash
# Usage: sudo kiosk-set-url https://example.com
usage() { echo "Usage: kiosk-set-url https://example.com"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
url="${1:-}"
case "$url" in http://?*|https://?*) ;; *) usage ;; esac
case "$url" in *[[:space:]\"\'\`\$\\]*) usage ;; esac
tmp="$(mktemp)"
grep -v '^START_URL=' /etc/kiosk/kiosk.conf >"$tmp"
printf 'START_URL="%s"\n' "$url" >>"$tmp"
install -m 644 "$tmp" /etc/kiosk/kiosk.conf
rm -f "$tmp"
echo "Start page set to $url. Restarting the kiosk session..."
exec /usr/local/sbin/kiosk-restart-session
EOF
    chmod 755 /usr/local/sbin/kiosk-restart-session /usr/local/sbin/kiosk-set-url
}

write_browser_policies() {
    if [ "$BROWSER" = "chromium" ]; then
        install -d -m 755 "$CHROMIUM_POLICY_DIR"
        cat >"$CHROMIUM_POLICY_DIR/kiosk.json" <<EOF
{
  "IncognitoModeAvailability": 2,
  "DeveloperToolsAvailability": 2,
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "TranslateEnabled": false,
  "BackgroundModeEnabled": false,
  "PromptForDownloadLocation": false,
  "DownloadDirectory": "$KIOSK_HOME/Downloads",
  "URLBlocklist": ["chrome://flags", "chrome://inspect", "chrome://policy", "chrome://settings", "view-source:*"]
}
EOF
    else
        local dir="/usr/lib/$BROWSER/distribution"
        install -d -m 755 "$dir"
        cat >"$dir/policies.json" <<EOF
{
  "policies": {
    "DisableAppUpdate": true,
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableFirefoxAccounts": true,
    "DisableDeveloperTools": true,
    "DontCheckDefaultBrowser": true,
    "OfferToSaveLogins": false,
    "PasswordManagerEnabled": false,
    "NoDefaultBookmarks": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "PromptForDownloadLocation": false,
    "DownloadDirectory": "$KIOSK_HOME/Downloads",
    "RequestedLocales": ["en-US"]
  }
}
EOF
    fi
}

step_session() {
    say "Writing the kiosk session"
    write_session_files
    write_admin_helpers
    write_browser_policies

    # Default file manager for "show in folder" from the browser
    cat >/etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
inode/directory=pcmanfm.desktop
EOF

    # Autologin on tty1
    install -d /etc/systemd/system/getty@tty1.service.d
    cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
Type=idle
EOF

    # Start X for the kiosk user only (root-owned, so guests cannot tamper with it)
    cat >/etc/profile.d/kiosk-autostart.sh <<'EOF'
# Start the kiosk X session on tty1 for the kiosk user only.
if [ -r /etc/kiosk/kiosk.conf ]; then
    . /etc/kiosk/kiosk.conf
    if [ "$(id -un)" = "$KIOSK_USER" ] && [ -z "${DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = "1" ]; then
        startx /usr/local/lib/kiosk/session.sh -- -nolisten tcp "vt${XDG_VTNR}" >"$HOME/.kiosk-session.log" 2>&1
        sleep 3   # avoid a tight respawn loop if X keeps failing
        exit 0
    fi
fi
EOF
    chmod 644 /etc/profile.d/kiosk-autostart.sh
    systemctl daemon-reload
}

# ----------------------------------------------------------------------------
# Lockdown
# ----------------------------------------------------------------------------
step_lockdown() {
    say "Locking the system down for guests"
    install -d /etc/X11/xorg.conf.d
    cat >/etc/X11/xorg.conf.d/10-kiosk-server.conf <<'EOF'
Section "ServerFlags"
    Option "DontVTSwitch" "true"
    Option "DontZap" "true"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
EOF

    install -d /etc/systemd/logind.conf.d
    cat >/etc/systemd/logind.conf.d/10-kiosk.conf <<'EOF'
[Login]
NAutoVTs=0
ReserveVT=0
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF
    local u
    for u in ctrl-alt-del.target sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        systemctl mask "$u" >/dev/null 2>&1 || true
    done
}

# ----------------------------------------------------------------------------
# Updates, reboot, journal
# ----------------------------------------------------------------------------
step_updates() {
    say "Configuring security-only automatic updates and nightly reboot"
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    # 99- sorts after the stock 50unattended-upgrades: clear its origins, keep security only.
    # (The Debian security suite codename is "<release>-security" since Debian 11.)
    cat >/etc/apt/apt.conf.d/99kiosk-security-only <<'EOF'
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    cat >/etc/cron.d/kiosk-reboot <<'EOF'
# Nightly reboot: applies kernel updates and gives every day a clean start
0 2 * * * root /sbin/shutdown -r now "Scheduled kiosk reboot"
EOF
    chmod 644 /etc/cron.d/kiosk-reboot

    install -d /etc/systemd/journald.conf.d
    cat >/etc/systemd/journald.conf.d/10-kiosk.conf <<'EOF'
[Journal]
SystemMaxUse=50M
EOF
}

# ----------------------------------------------------------------------------
# USB read-only
# ----------------------------------------------------------------------------
step_usb() {
    [ "$USB_RO" = 1 ] || return 0
    say "Making USB storage read-only"
    local root_src
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [ -n "$root_src" ] && lsblk -sno TRAN "$root_src" 2>/dev/null | grep -qx usb; then
        warn "The system disk is on USB: skipping the USB read-only rule (it would freeze the system)."
        return 0
    fi
    cat >/etc/udev/rules.d/99-kiosk-usb-readonly.rules <<'EOF'
# Kiosk: every USB block device (disks and partitions) is read-only
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="/sbin/blockdev --setro /dev/%k"
EOF
    install -d /etc/udisks2
    cat >/etc/udisks2/mount_options.conf <<'EOF'
[defaults]
defaults=ro,nosuid,nodev,noexec
EOF
    udevadm control --reload-rules 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# SSH
# ----------------------------------------------------------------------------
step_ssh() {
    [ "$WANT_SSH" = 1 ] || return 0
    say "Configuring SSH"
    if [ "$CREATE_ADMIN" = 1 ]; then
        adduser --gecos "" "$ADMIN_USER" </dev/tty >/dev/tty
    fi
    apt_install openssh-server
    apt_try avahi-daemon   # lets you reach the machine as <hostname>.local

    local home
    home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    if [ -n "$ADMIN_PUBKEY" ]; then
        install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
        touch "$home/.ssh/authorized_keys"
        grep -qxF "$ADMIN_PUBKEY" "$home/.ssh/authorized_keys" || echo "$ADMIN_PUBKEY" >>"$home/.ssh/authorized_keys"
        chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
    fi

    install -d -m 755 /etc/ssh/sshd_config.d
    {
        echo "PermitRootLogin no"
        echo "AllowUsers $ADMIN_USER"
        echo "MaxAuthTries 4"
        echo "X11Forwarding no"
        [ -n "$ADMIN_PUBKEY" ] && echo "PasswordAuthentication no"
    } >/etc/ssh/sshd_config.d/10-kiosk.conf

    if sshd -t 2>/dev/null; then
        systemctl enable ssh >/dev/null 2>&1 || true
        systemctl restart ssh
    else
        warn "sshd config test failed: removing my SSH settings."
        rm -f /etc/ssh/sshd_config.d/10-kiosk.conf
    fi
}

# ----------------------------------------------------------------------------
# Network (NetworkManager: Ethernet + Wi-Fi)
# ----------------------------------------------------------------------------
step_network() {
    say "Configuring networking (NetworkManager)"
    apt_install network-manager wpasupplicant
    apt_try wireless-regdb iw

    if ! grep -q 'Managed by NetworkManager (kiosk-setup)' /etc/network/interfaces 2>/dev/null; then
        [ -f /etc/network/interfaces ] && cp -a /etc/network/interfaces /etc/network/interfaces.kiosk-backup
        cat >/etc/network/interfaces <<'EOF'
# Managed by NetworkManager (kiosk-setup). Original saved as interfaces.kiosk-backup
auto lo
iface lo inet loopback
EOF
    fi

    if [ -n "$WIFI_SSID" ]; then
        local f="/etc/NetworkManager/system-connections/kiosk-wifi.nmconnection" uuid
        uuid="$(cat /proc/sys/kernel/random/uuid)"
        install -d -m 755 /etc/NetworkManager/system-connections
        umask 077
        {
            printf '[connection]\nid=kiosk-wifi\nuuid=%s\ntype=wifi\nautoconnect=true\n\n' "$uuid"
            printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$WIFI_SSID"
            if [ -n "$WIFI_PSK" ]; then
                printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$WIFI_PSK"
            fi
            printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
        } >"$f"
        umask 022
        chmod 600 "$f"
    fi
    systemctl enable NetworkManager >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# Boot speed, slimming
# ----------------------------------------------------------------------------
set_grub_var() { # set_grub_var KEY VALUE [file]
    local key="$1" val="$2" file="${3:-/etc/default/grub}"
    if grep -qE "^${key}=" "$file"; then
        sed -i -E "s|^${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >>"$file"
    fi
}

step_boot() {
    [ "$BOOTOPT" = 1 ] || return 0
    say "Optimizing boot"
    local u
    for u in NetworkManager-wait-online.service systemd-networkd-wait-online.service \
             man-db.timer e2scrub_all.timer e2scrub_reap.service; do
        systemctl mask "$u" >/dev/null 2>&1 || true
    done
    if [ -f /etc/default/grub ]; then
        set_grub_var GRUB_TIMEOUT 0
        set_grub_var GRUB_TIMEOUT_STYLE hidden
        set_grub_var GRUB_CMDLINE_LINUX_DEFAULT '"quiet loglevel=3 consoleblank=0"'
        command -v update-grub >/dev/null 2>&1 && update-grub
    else
        warn "No /etc/default/grub (not using GRUB?): skipped bootloader tweaks."
    fi
}

step_slim() {
    if [ "$SLIM" = 1 ]; then
        say "Removing unused languages and man pages"
        debconf-set-selections <<'EOF'
localepurge localepurge/nopurge multiselect en, en_US, en_US.UTF-8, it, it_IT, it_IT.UTF-8
localepurge localepurge/mandelete boolean true
localepurge localepurge/dontbothernew boolean false
localepurge localepurge/quickndirtycalc boolean false
localepurge localepurge/use-dpkg-feature boolean false
EOF
        apt_install localepurge
        localepurge || true
        apt-get purge -y manpages >/dev/null 2>&1 || true
    fi
    say "Cleaning up packages"
    apt-get autoremove --purge -y
    apt-get clean
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    need_root "$@"
    setup_logging
    check_system
    collect_answers
    confirm_answers

    step_apt
    step_packages
    step_user
    step_locale_keyboard
    step_hostname
    step_session
    step_lockdown
    step_updates
    step_usb
    step_ssh
    step_network
    step_boot
    step_slim

    say "Done!"
    cat <<EOF

Kiosk installed. After the reboot the machine logs in as '$KIOSK_USER' and opens
$START_URL in $BROWSER.

Useful commands (as root / sudo):
  kiosk-set-url https://new.example.com   change the start page and restart the session
  kiosk-restart-session                   restart the guest session
  systemd-analyze                         boot time (after the first reboot)
  Log of this installation: $LOG_FILE

Read README.md for printers, SSH keys, Wi-Fi and troubleshooting.
EOF
    if [ "$DO_REBOOT" = 1 ]; then
        echo "Rebooting in 10 seconds (Ctrl+C to cancel)..."
        sleep 10
        systemctl reboot
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
