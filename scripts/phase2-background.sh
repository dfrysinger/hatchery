#!/bin/bash
# =============================================================================
# phase2-background.sh -- Background setup: desktop, tools, remote access
# =============================================================================
# Purpose:  Second phase of droplet provisioning, runs in the background after
#           phase1 gets the bot online. Installs desktop environment (XFCE),
#           developer tools, Chrome, configures VNC/XRDP remote access,
#           installs skills, sets up email/calendar/Dropbox, builds full
#           clawdbot config, and reboots.
#
# Inputs:   /etc/droplet.env -- all B64-encoded secrets and config
#           /etc/habitat-parsed.env -- parsed habitat config
#
# Outputs:  Desktop environment on :10, XRDP on port 3389, VNC on 5900 (localhost only)
#           Skills installed, full config built, state restored from Dropbox
#           /var/lib/init-status/phase2-complete -- completion marker
#
# Dependencies: apt-get, npm, set-stage.sh, build-full-config.sh,
#               restore-clawdbot-state.sh, tg-notify.sh
#
# Original: /usr/local/sbin/phase2-background.sh (in hatch.yaml write_files)
# =============================================================================
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
S="/usr/local/bin/set-stage.sh"
LOG="/var/log/phase2.log"
START=$(date +%s)
H="/home/$USERNAME"
CHROME_PID=$(cat /tmp/downloads/chrome.pid 2>/dev/null)
[ -n "$CHROME_PID" ] && wait $CHROME_PID 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
sleep 2
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock
dpkg --configure -a 2>/dev/null || true
$S 4 "desktop-environment"
apt-get update -qq >> "$LOG" 2>&1
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y --no-install-recommends \
  xrdp xorgxrdp xvfb x11vnc lightdm dbus-x11 xserver-xorg-video-dummy \
  xfce4 xfce4-goodies xfce4-terminal elementary-xfce-icon-theme \
  >> "$LOG" 2>&1
$S 5 "developer-tools"
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y --no-install-recommends \
  build-essential git gh ffmpeg imagemagick vlc libreoffice-writer \
  thunderbird pandoc scrot flameshot qpdf jq htop ncdu bc wget xz-utils \
  python3 python3-pip rclone fuse3 khal vdirsyncer unattended-upgrades \
  >> "$LOG" 2>&1
rm -f /etc/xdg/autostart/xfce4-screensaver.desktop
apt-get purge -y xfce4-screensaver gnome-keyring libpam-gnome-keyring seahorse 2>/dev/null || true
$S 6 "browser-tools"
[ -f /tmp/downloads/chrome.deb ] && dpkg -i /tmp/downloads/chrome.deb >> "$LOG" 2>&1
rm -f /tmp/downloads/chrome.deb
apt-get -f install -y >> "$LOG" 2>&1
mkdir -p $H/.config/chrome-debug/Default
echo '{"browser":{"default_browser_infobar_last_declined":"99999999999999.0","default_browser_setting_enabled":false}}' > "$H/.config/chrome-debug/Local State"
echo '{"browser":{"check_default_browser":false},"session":{"restore_on_startup":1},"distribution":{"skip_first_run_ui":true,"suppress_first_run_default_browser_prompt":true}}' > "$H/.config/chrome-debug/Default/Preferences"
touch "$H/.config/chrome-debug/First Run"
chown -R $USERNAME:$USERNAME $H/.config/chrome-debug
PIP_BREAK_SYSTEM_PACKAGES=1 pip3 install -U yt-dlp google-auth google-api-python-client >> "$LOG" 2>&1
curl -sSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh | sh >> "$LOG" 2>&1
[ -f /root/.local/bin/himalaya ] && ln -sf /root/.local/bin/himalaya /usr/local/bin/himalaya
# Download helper scripts (platform-safe set-council-group wrapper is provided via cloud-init write_files)
curl -sf -o "/usr/local/bin/gmail-api.py" "https://raw.githubusercontent.com/dfrysinger/hatchery/main/gmail-api.py" \
  && chmod 755 "/usr/local/bin/gmail-api.py" >> "$LOG" 2>&1 \
  || echo "WARN: Failed to download gmail-api.py" >> "$LOG"
curl -sf -o "/usr/local/bin/set-council-group.telegram.sh" "https://raw.githubusercontent.com/dfrysinger/hatchery/main/set-council-group.sh" \
  && chmod 755 "/usr/local/bin/set-council-group.telegram.sh" >> "$LOG" 2>&1 \
  || echo "WARN: Failed to download set-council-group.telegram.sh" >> "$LOG"
$S 7 "desktop-services"
cat > /etc/systemd/system/xvfb.service <<SVC
[Unit]
Description=Xvfb on :10
After=network.target
[Service]
Type=simple
User=$USERNAME
ExecStart=/usr/bin/Xvfb :10 -screen 0 1920x1080x24 -ac
Restart=always
[Install]
# WantedBy removed - started explicitly after phase2 completes
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
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $USERNAME)
ExecStartPre=/bin/bash -c 'UID_NUM=$(id -u $USERNAME); mkdir -p /run/user/\$UID_NUM && chown $USERNAME:$USERNAME /run/user/\$UID_NUM && chmod 700 /run/user/\$UID_NUM'
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
# WantedBy removed - started explicitly after phase2 completes
SVC
mkdir -p $H/.config/xfce4/xfconf/xfce-perchannel-xml
chown -R $USERNAME:$USERNAME $H/.config
systemctl daemon-reload
systemctl enable xvfb desktop x11vnc
# Moved to end: systemctl start xvfb
# sleep 2
# Moved to end: systemctl start desktop
# sleep 3
# Moved to end: systemctl start x11vnc
mkdir -p $H/Desktop
cat > $H/Desktop/google-chrome.desktop <<'DESK'
[Desktop Entry]
Version=1.0
Name=Google Chrome
Exec=/usr/bin/google-chrome-stable --password-store=basic --no-first-run --no-default-browser-check --disable-sync --remote-debugging-port=18800 --user-data-dir=/home/bot/.config/chrome-debug %U
Terminal=false
Icon=google-chrome
Type=Application
DESK
cat > $H/Desktop/dropbox.desktop <<'DESK'
[Desktop Entry]
Version=1.0
Type=Application
Name=Mount Dropbox
Exec=/usr/local/bin/mount-dropbox.sh
Icon=folder-remote
Terminal=false
DESK
chmod +x $H/Desktop/*.desktop
chown -R $USERNAME:$USERNAME $H/Desktop
$S 8 "skills-apps"
npm install -g clawhub@latest >> "$LOG" 2>&1
for s in weather github video-frames goplaces youtube-transcript yt-dlp-downloader-skill; do
  su - $USERNAME -c "cd $H/clawd && clawhub install $s" >> "$LOG" 2>&1 || true
done
find $H/clawd/skills -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
DBT=$(d "$DROPBOX_TOKEN_B64"); EM=$(d "$EMAIL_B64"); EP=$(d "$EMAIL_PASSWORD_B64")
IH=$(d "$IMAP_HOST_B64"); GHT=$(d "$GH_TOKEN_B64")
mkdir -p $H/.config/{himalaya,rclone,gh}
[ -n "$DBT" ] && echo -e "[dropbox]\ntype = dropbox\ntoken = $DBT" > $H/.config/rclone/rclone.conf
[ -n "$EM" ] && [ -n "$EP" ] && cat > $H/.config/himalaya/config.toml <<HIM
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
[ -n "$GHT" ] && echo -e "github.com:\n    oauth_token: ${GHT}\n    git_protocol: https" > $H/.config/gh/hosts.yml
CU=$(d "$CALDAV_URL_B64"); CUN=$(d "$CALDAV_USER_B64"); CP=$(d "$CALDAV_PASSWORD_B64")
if [ -n "$CU" ] && [ -n "$CUN" ]; then
  mkdir -p $H/.config/vdirsyncer $H/.config/khal
  mkdir -p $H/.local/share/vdirsyncer/status $H/.local/share/khal/calendars
  cat > $H/.config/vdirsyncer/config <<VDSCFG
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
  cat > $H/.config/khal/config <<KHALCFG
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
  chown -R $USERNAME:$USERNAME $H/.config/vdirsyncer $H/.config/khal $H/.local/share/vdirsyncer $H/.local/share/khal
  su - $USERNAME -c "yes | vdirsyncer discover" >> "$LOG" 2>&1 || true
  su - $USERNAME -c "vdirsyncer sync" >> "$LOG" 2>&1 || true
fi
chown -R $USERNAME:$USERNAME $H/.config
$S 9 "remote-access"
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
systemctl enable xrdp
systemctl restart xrdp
ufw allow 3389/tcp
#ufw allow 5900/tcp  # REMOVED: VNC accessible via RDP tunnel only (security)
$S 10 "finalizing"
/usr/local/bin/restore-clawdbot-state.sh
/usr/local/sbin/build-full-config.sh
systemctl enable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
systemctl enable clawdbot-sync.timer 2>/dev/null || true
systemctl start clawdbot-sync.timer 2>/dev/null || true
# Start desktop services now that everything is installed
$S 9 "starting-desktop"
systemctl start xvfb
sleep 2
systemctl start desktop
sleep 3
systemctl start x11vnc
systemctl restart xrdp

touch /var/lib/init-status/phase2-complete
touch /var/lib/init-status/needs-post-boot-check
GT=$(cat /home/bot/.clawdbot/gateway-token.txt 2>/dev/null)
[ -n "$GT" ] && curl -sf -X POST http://localhost:18789/api/cron/wake \
  -H "Authorization: Bearer $GT" -H "Content-Type: application/json" \
  -d '{"mode":"now"}' >> "$LOG" 2>&1 || true
END=$(date +%s)
DURATION=$((END - START))
TG="/usr/local/bin/tg-notify.sh"
HN="${HABITAT_NAME:-default}"
HDOM="${HABITAT_DOMAIN:+ ($HABITAT_DOMAIN)}"
$TG "[SETUP COMPLETE] ${HN}${HDOM} ready. Phase 2 finished in ${DURATION}s. Rebooting... Back shortly!" || true
sleep 5
reboot
