#!/bin/bash
# =============================================================================
# provision.sh — Single-phase droplet provisioning
# =============================================================================
# Replaces the phase1-critical.sh → phase2-background.sh background fork.
# One script, sequential stages, no background fork. Ends with REBOOT.
#
# Called by: bootstrap.sh (which is called by cloud-init runcmd)
#
# Stages:
#   1. Parse config + install Node/jq + start API server
#   2. Install OpenClaw (npm)
#   3. Create user + workspace + gateway token
#   4. Install desktop packages (apt)
#   5. Install developer tools (apt)
#   6. Install Chrome, pip packages & helpers
#   7. Configure desktop + apps + build config + enable services
#   8. REBOOT
#
# After reboot: systemd starts enabled services → health check → E2E
# Reboot is REQUIRED: packages need kernel modules, systemd needs
# daemon-reload, avoids weird state from halfway-installed packages.
# =============================================================================

set -o pipefail

# CRITICAL: Set permissive umask for the entire provisioning run.
# DO images default to umask 077 (root creates files as rwx------).
# This causes permission failures when bot user tries to read/execute
# files created by root (npm packages, config files, etc.).
# umask 022 = standard Linux default: owner rwx, group+other rx.
umask 022

LOG="/var/log/provision.log"
START=$(date +%s)

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [provision] $*" | tee -a "$LOG"; }

# Source permission utilities
[ -f /usr/local/sbin/lib-permissions.sh ] && source /usr/local/sbin/lib-permissions.sh

# lib-env.sh may not be installed yet during early provisioning — inline fallback
for _lib_path in /usr/local/sbin /usr/local/bin "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
  [ -f "$_lib_path/lib-env.sh" ] && { source "$_lib_path/lib-env.sh"; break; }
done
if ! type d &>/dev/null; then
  # Inline fallback for first boot before lib-env.sh is deployed
  d() { [ -n "${1:-}" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
fi
set -a; source /etc/droplet.env; set +a

S="/usr/local/bin/set-stage.sh"

# =============================================================================
# Stage 1: Parse habitat config + install Node
# =============================================================================
$S 1 "parsing-config"
log "Stage 1: Parsing habitat config..."

if ! python3 /usr/local/bin/parse-habitat.py; then
  log "WARN: parse-habitat.py failed, using fallback"
  python3 << 'FALLBACK_PY' >> /etc/habitat-parsed.env 2>/dev/null || true
import base64, json, os
try:
    h = json.loads(base64.b64decode(os.environ.get('HABITAT_B64', '')).decode())
except:
    h = {}
print('HABITAT_NAME="broken"')
print('AGENT_COUNT=1')
a = h.get('agents', [{}])[0] if h.get('agents') else {}
print(f'AGENT1_NAME="{a.get("name", "Claude")}"')
plat = h.get('platform', '')
if not plat:
    if h.get('platforms', {}).get('discord') or h.get('discord'):
        plat = 'discord'
    elif h.get('platforms', {}).get('telegram') or a.get('botToken') or a.get('tokens', {}).get('telegram'):
        plat = 'telegram'
    else:
        plat = 'telegram'
print(f'PLATFORM="{plat}"')
tg_tok = a.get('tokens', {}).get('telegram', '') or a.get('botToken', '')
print(f'AGENT1_BOT_TOKEN="{tg_tok}"')
dc_tok = a.get('tokens', {}).get('discord', '') or a.get('discordBotToken', '')
print(f'AGENT1_DISCORD_BOT_TOKEN="{dc_tok}"')
dc_owner = h.get('platforms', {}).get('discord', {}).get('ownerId', '') or h.get('discordOwnerId', '') or h.get('discord', {}).get('ownerId', '')
dc_guild = h.get('platforms', {}).get('discord', {}).get('guildId', '') or h.get('discordGuildId', '') or h.get('discord', {}).get('guildId', '')
tg_owner = h.get('platforms', {}).get('telegram', {}).get('ownerId', '') or h.get('telegram', {}).get('ownerId', '')
print(f'DISCORD_OWNER_ID="{dc_owner}"')
print(f'DISCORD_GUILD_ID="{dc_guild}"')
if tg_owner:
    print(f'TELEGRAM_USER_ID="{tg_owner}"')
FALLBACK_PY
fi

source /etc/habitat-parsed.env

# Install Node (parallel download started in bootcmd)
log "Installing Node.js..."
NODE_PID=$(cat /tmp/downloads/node.pid 2>/dev/null)
[ -n "$NODE_PID" ] && wait "$NODE_PID" 2>/dev/null || true
if [ -f /tmp/downloads/node.tar.xz ]; then
  tar -xJf /tmp/downloads/node.tar.xz -C /usr/local --strip-components=1 >> "$LOG" 2>&1
  rm -f /tmp/downloads/node.tar.xz
else
  apt-get update -qq && apt-get install -y nodejs npm >> "$LOG" 2>&1
fi
apt-get install -y jq >> "$LOG" 2>&1 || true

# Start API server early so iOS Shortcut can track provisioning stages
if [ ! -f /etc/systemd/system/api-server.service ]; then
  cat > /etc/systemd/system/api-server.service <<'APISVC'
[Unit]
Description=Droplet Status API
After=network.target
[Service]
EnvironmentFile=-/etc/api-server.env
EnvironmentFile=-/etc/habitat-parsed.env
ExecStart=/usr/local/bin/api-server.py
Restart=always
RestartSec=3
User=root
[Install]
WantedBy=multi-user.target
APISVC
fi
if [ ! -f /etc/api-server.env ]; then
  if [ -n "$API_SECRET_B64" ] && [ "$API_SECRET_B64" != "[[API_SECRET_B64]]" ]; then
    API_SECRET=$(echo "$API_SECRET_B64" | base64 -d)
  else
    API_SECRET=$(openssl rand -hex 32)
  fi
  (umask 077; printf 'API_SECRET=%s\n' "$API_SECRET" > /etc/api-server.env; chmod 600 /etc/api-server.env)
fi
systemctl daemon-reload
systemctl enable --now api-server || true

# =============================================================================
# Stage 2: Install OpenClaw
# =============================================================================
$S 2 "installing-openclaw"
log "Stage 2: Installing OpenClaw..."

npm install -g openclaw@latest >> "$LOG" 2>&1

# =============================================================================
# Stage 3: Create user + workspace
# =============================================================================
$S 3 "creating-workspace"
log "Stage 3: Creating user + workspace..."

PW=$(d "$PASSWORD_B64")
USERNAME="${USERNAME:-bot}"
id "$USERNAME" &>/dev/null || useradd -m -s /bin/bash -G sudo "$USERNAME"
echo "$USERNAME:$PW" | chpasswd
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
H="/home/$USERNAME"
chown "$USERNAME:$USERNAME" "$H"

# Decode secrets
AK=$(d "$ANTHROPIC_API_KEY_B64")
GK=$(d "$GOOGLE_API_KEY_B64")
GCID=$(d "$GMAIL_CLIENT_ID_B64"); GSEC=$(d "$GMAIL_CLIENT_SECRET_B64"); GRTK=$(d "$GMAIL_REFRESH_TOKEN_B64")
OK=$(d "$OPENAI_KEY_B64")
GT=$(openssl rand -hex 24)
AC="${AGENT_COUNT:-1}"

# Create workspace directories and config files
# (umask 022 ensures these are world-readable; chown at end gives bot ownership)
mkdir -p "$H/.openclaw" "$H/clawd/shared"
for i in $(seq 1 "$AC"); do
  mkdir -p "$H/clawd/agents/agent${i}/memory"
done
echo "$GT" > "$H/.openclaw/gateway-token.txt"

# .env with API keys
{
  echo "ANTHROPIC_API_KEY=${AK}"
  [ -n "$GK" ] && echo -e "GOOGLE_API_KEY=${GK}\nGEMINI_API_KEY=${GK}"
  [ -n "$OK" ] && echo "OPENAI_API_KEY=${OK}"
  [ -n "$GCID" ] && echo -e "GMAIL_CLIENT_ID=${GCID}\nGMAIL_CLIENT_SECRET=${GSEC}\nGMAIL_REFRESH_TOKEN=${GRTK}"
} > "$H/.openclaw/.env"

# Fix ownership + tighten sensitive files
chown -R "$USERNAME:$USERNAME" "$H/.openclaw" "$H/clawd"
chmod 700 "$H/.openclaw"
chmod 600 "$H/.openclaw/gateway-token.txt" "$H/.openclaw/.env"

# =============================================================================
# Stage 4: Install desktop packages (apt)
# =============================================================================
$S 4 "installing-desktop"
log "Stage 4: Installing desktop packages..."

# Wait for Chrome download (started in bootcmd)
CHROME_PID=$(cat /tmp/downloads/chrome.pid 2>/dev/null)
[ -n "$CHROME_PID" ] && wait "$CHROME_PID" 2>/dev/null || true

# Stop apt timers that might hold the lock (no killall needed — no background fork)
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
sleep 2
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock
dpkg --configure -a 2>/dev/null || true

# Desktop environment + display server
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y --no-install-recommends \
  xrdp xorgxrdp xvfb x11vnc lightdm dbus-x11 xserver-xorg-video-dummy \
  xfce4 xfce4-goodies xfce4-terminal elementary-xfce-icon-theme yaru-theme-gtk \
  python3 python3-pip \
  >> "$LOG" 2>&1

rm -f /etc/xdg/autostart/xfce4-screensaver.desktop
apt-get purge -y xfce4-screensaver gnome-keyring libpam-gnome-keyring seahorse 2>/dev/null || true

# =============================================================================
# Stage 5: Install developer tools (apt)
# =============================================================================
$S 5 "installing-tools"
log "Stage 5: Installing developer tools..."

DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y --no-install-recommends \
  build-essential git gh ffmpeg imagemagick vlc libreoffice-writer \
  thunderbird pandoc scrot flameshot qpdf htop ncdu bc wget xz-utils \
  rclone fuse3 khal vdirsyncer unattended-upgrades \
  >> "$LOG" 2>&1

# =============================================================================
# Stage 6: Install Chrome, pip packages & helper scripts
# =============================================================================
$S 6 "installing-extras"
log "Stage 6: Installing Chrome, pip packages & helpers..."

# Chrome
[ -f /tmp/downloads/chrome.deb ] && dpkg -i /tmp/downloads/chrome.deb >> "$LOG" 2>&1
rm -f /tmp/downloads/chrome.deb
apt-get -f install -y >> "$LOG" 2>&1

# pip + himalaya
PIP_BREAK_SYSTEM_PACKAGES=1 pip3 install -U yt-dlp google-auth google-api-python-client >> "$LOG" 2>&1
curl -sSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh | sh >> "$LOG" 2>&1
[ -f /root/.local/bin/himalaya ] && ln -sf /root/.local/bin/himalaya /usr/local/bin/himalaya

# Helper scripts
curl -sf -o "/usr/local/bin/gmail-api.py" "https://raw.githubusercontent.com/dfrysinger/hatchery/main/gmail-api.py" \
  && chmod 755 "/usr/local/bin/gmail-api.py" >> "$LOG" 2>&1 || true
curl -sf -o "/usr/local/bin/set-council-group.telegram.sh" "https://raw.githubusercontent.com/dfrysinger/hatchery/main/set-council-group.sh" \
  && chmod 755 "/usr/local/bin/set-council-group.telegram.sh" >> "$LOG" 2>&1 || true

# =============================================================================
# Stage 7: Configure + build + enable services
# =============================================================================
$S 7 "configuring"
log "Stage 7: Configuring desktop, apps & services..."

cat > /etc/systemd/system/xvfb.service <<SVC
[Unit]
Description=Xvfb on :10
After=network.target
[Service]
Type=simple
User=$USERNAME
ExecStart=/bin/bash -c 'echo \$\$ > /tmp/xvfb.pid && exec /usr/bin/Xvfb :10 -screen 0 1920x1080x24 -ac'
ExecStopPost=/bin/rm -f /tmp/xvfb.pid
Restart=always
[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/desktop.service <<SVC
[Unit]
Description=XFCE Desktop
After=xvfb.service
Requires=xvfb.service
[Service]
Type=simple
User=$USERNAME
Environment=DISPLAY=:10
Environment=HOME=$H
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "$USERNAME")
ExecStartPre=+/bin/bash -c 'UID_NUM=$(id -u $USERNAME); mkdir -p /run/user/\$UID_NUM && chown $USERNAME:$USERNAME /run/user/\$UID_NUM && chmod 700 /run/user/\$UID_NUM'
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/dbus-launch --exit-with-session /usr/bin/xfce4-session
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/x11vnc.service <<SVC
[Unit]
Description=x11vnc
After=desktop.service
Requires=desktop.service
[Service]
Type=simple
User=$USERNAME
Environment=DISPLAY=:10
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/x11vnc -display :10 -rfbport 5900 -forever -nopw -shared -noxdamage -noxrecord -fs 1.0 -defer 10 -wait 5
Restart=always
RestartSec=5
[Install]
WantedBy=desktop.service
SVC

# Chrome debug profile
mkdir -p "$H/.config/chrome-debug/Default"
echo '{"browser":{"default_browser_infobar_last_declined":"99999999999999.0","default_browser_setting_enabled":false}}' > "$H/.config/chrome-debug/Local State"
echo '{"browser":{"check_default_browser":false},"session":{"restore_on_startup":1},"distribution":{"skip_first_run_ui":true,"suppress_first_run_default_browser_prompt":true}}' > "$H/.config/chrome-debug/Default/Preferences"
touch "$H/.config/chrome-debug/First Run"

# Desktop background color
mkdir -p "$H/.config/xfce4/xfconf/xfce-perchannel-xml"
if [ -n "$BG_COLOR" ] && [ ${#BG_COLOR} -eq 6 ]; then
  R=$(printf "%.5f" "$(echo "scale=5; $((16#${BG_COLOR:0:2}))/255" | bc)")
  G=$(printf "%.5f" "$(echo "scale=5; $((16#${BG_COLOR:2:2}))/255" | bc)")
  B=$(printf "%.5f" "$(echo "scale=5; $((16#${BG_COLOR:4:2}))/255" | bc)")
  cat > "$H/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" <<BGXML
<?xml version="1.0"?><channel name="xfce4-desktop" version="1.0"><property name="backdrop" type="empty"><property name="screen0" type="empty"><property name="monitorscreen" type="empty"><property name="workspace0" type="empty"><property name="color-style" type="int" value="0"/><property name="image-style" type="int" value="0"/><property name="rgba1" type="array"><value type="double" value="${R}"/><value type="double" value="${G}"/><value type="double" value="${B}"/><value type="double" value="1"/></property></property></property></property></property></channel>
BGXML
fi

# Desktop shortcuts
mkdir -p "$H/Desktop"
cat > "$H/Desktop/google-chrome.desktop" <<'DESK'
[Desktop Entry]
Version=1.0
Name=Google Chrome
Exec=/usr/bin/google-chrome-stable --password-store=basic --no-first-run --no-default-browser-check --disable-sync --remote-debugging-port=18800 --user-data-dir=/home/bot/.config/chrome-debug %U
Terminal=false
Icon=google-chrome
Type=Application
DESK
cat > "$H/Desktop/dropbox.desktop" <<'DESK'
[Desktop Entry]
Version=1.0
Type=Application
Name=Mount Dropbox
Exec=/usr/local/bin/mount-dropbox.sh
Icon=folder-remote
Terminal=false
DESK
chmod +x "$H/Desktop"/*.desktop

chown -R "$USERNAME:$USERNAME" "$H/.config" "$H/Desktop"

# XRDP config
adduser xrdp ssl-cert 2>/dev/null || true
cat >> /etc/xrdp/xrdp.ini <<'XI'

[vnc-local]
name=Shared Desktop (:10)
lib=libvnc.so
ip=127.0.0.1
port=5900
username=na
password=ask
delay_ms=50
xserverbpp=24
disabled_encodings_mask=0
XI
sed -i 's/^autorun=$/autorun=vnc-local/' /etc/xrdp/xrdp.ini
echo -e "#!/bin/sh\nunset DBUS_SESSION_BUS_ADDRESS\nunset XDG_RUNTIME_DIR\nexec dbus-launch --exit-with-session startxfce4" > /etc/xrdp/startwm.sh
chmod 755 /etc/xrdp/startwm.sh
sed -i 's/^X11DisplayOffset=.*/X11DisplayOffset=10/' /etc/xrdp/sesman.ini
systemctl unmask xrdp xrdp-sesman
systemctl daemon-reload
systemctl enable xvfb desktop x11vnc xrdp

# --- Apps & integrations ---

# Skills
npm install -g clawhub@latest >> "$LOG" 2>&1
# umask 022 ensures npm packages are world-readable (no chmod fix needed)
for s in weather github video-frames goplaces youtube-transcript yt-dlp-downloader-skill; do
  su - "$USERNAME" -c "cd $H/clawd && clawhub install $s" >> "$LOG" 2>&1 || true
done
find "$H/clawd/skills" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Credentials
DBT=$(d "$DROPBOX_TOKEN_B64"); EM=$(d "$EMAIL_B64"); EP=$(d "$EMAIL_PASSWORD_B64")
IH=$(d "$IMAP_HOST_B64"); GHT=$(d "$GH_TOKEN_B64")
mkdir -p "$H/.config"/{himalaya,rclone,gh}
[ -n "$DBT" ] && echo -e "[dropbox]\ntype = dropbox\ntoken = $DBT" > "$H/.config/rclone/rclone.conf"
[ -n "$EM" ] && [ -n "$EP" ] && cat > "$H/.config/himalaya/config.toml" <<HIM
[accounts.default]
email = "${EM}"
default = true
backend.type = "imap"
backend.host = "${IH:-imap.gmail.com}"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "${EM}"
backend.auth.type = "password"
backend.auth.raw = "${EP}"
HIM
[ -n "$GHT" ] && echo -e "github.com:\n    oauth_token: ${GHT}\n    git_protocol: https" > "$H/.config/gh/hosts.yml"

# CalDAV
CU=$(d "$CALDAV_URL_B64"); CUN=$(d "$CALDAV_USER_B64"); CP=$(d "$CALDAV_PASSWORD_B64")
if [ -n "$CU" ] && [ -n "$CUN" ]; then
  mkdir -p "$H/.config/vdirsyncer" "$H/.config/khal" "$H/.local/share/vdirsyncer/status" "$H/.local/share/khal/calendars"
  cat > "$H/.config/vdirsyncer/config" <<VDSCFG
[general]
status_path = "~/.local/share/vdirsyncer/status/"
[pair calendar]
a = "calendar_local"
b = "calendar_remote"
collections = ["from a", "from b"]
metadata = ["color"]
[storage calendar_local]
type = "filesystem"
path = "~/.local/share/khal/calendars/"
fileext = ".ics"
[storage calendar_remote]
type = "caldav"
url = "${CU}"
username = "${CUN}"
password = "${CP}"
VDSCFG
  cat > "$H/.config/khal/config" <<KHALCFG
[calendars]
[[default]]
path = ~/.local/share/khal/calendars/*
type = discover
[locale]
timeformat = %H:%M
dateformat = %Y-%m-%d
longdateformat = %Y-%m-%d
datetimeformat = %Y-%m-%d %H:%M
longdatetimeformat = %Y-%m-%d %H:%M
KHALCFG
  chown -R "$USERNAME:$USERNAME" "$H/.config/vdirsyncer" "$H/.config/khal" "$H/.local/share/vdirsyncer" "$H/.local/share/khal"
  su - "$USERNAME" -c "yes | vdirsyncer discover" >> "$LOG" 2>&1 || true
  su - "$USERNAME" -c "vdirsyncer sync" >> "$LOG" 2>&1 || true
fi

chown -R "$USERNAME:$USERNAME" "$H/.config"

# --- Build OpenClaw configs + generate services ---

# Restore service — enable only, will run after reboot before openclaw
systemctl enable openclaw-restore.service 2>/dev/null || true

# Build the full config (creates services, safeguard units, etc.)
/usr/local/sbin/build-full-config.sh || {
  log "FATAL: build-full-config.sh failed"
  touch /var/lib/init-status/build-failed
}

# --- Enable services + firewall ---

# Firewall
ufw allow 8080/tcp   # API
ufw allow 18789/tcp  # OpenClaw
ufw allow 3389/tcp   # RDP

# Unattended upgrades
systemctl enable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer

# Memory sync — enable only, starts after reboot
systemctl enable openclaw-sync.timer 2>/dev/null || true

# Fix ownership and permissions (safety net — umask 022 handles most cases,
# but this catches anything created before umask was set or by subprocesses)
if type fix_bot_permissions &>/dev/null; then
  fix_bot_permissions "$H"
else
  chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}" 2>/dev/null || true
fi

# Mark provisioning complete (before reboot)
touch /var/lib/init-status/provision-complete
touch /var/lib/init-status/needs-post-boot-check

ELAPSED=$(( $(date +%s) - START ))
log "Provisioning complete in ${ELAPSED}s — rebooting"

# =============================================================================
# Stage 8: REBOOT
# =============================================================================
# Reboot is REQUIRED:
# - Packages need kernel modules loaded (xrdp, chrome sandbox)
# - systemd needs clean daemon-reload after new unit files
# - Avoids weird state from halfway-installed packages
# - All services are enabled and will start automatically on boot

if [ -f /var/lib/init-status/build-failed ]; then
  log "!!! BUILD FAILED — rebooting anyway but services will not start correctly !!!"
fi

$S 8 "rebooting"
sleep 2
reboot
