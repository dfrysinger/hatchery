#!/bin/bash
# =============================================================================
# phase2-background.sh -- Background phase 2 provisioning (desktop/tools)
# =============================================================================
# Purpose:  Installs desktop environment, developer tools, browser, skills,
#           and configures all services after phase 1 (bot) is complete.
#
# Runs:     As background job spawned by phase1-critical.sh
# Stages:   4 (desktop-env) through 10 (finalizing)
# Log:      /var/log/phase2.log
# Marker:   Creates /var/lib/init-status/phase2-complete when done
#
# Original: /usr/local/sbin/phase2-background.sh (in hatch.yaml write_files)
# =============================================================================
set -a; source /etc/droplet.env; set +a
d() { [ -n "$1" ] && echo "$1" | base64 -d 2>/dev/null || echo ""; }
[ -f /etc/habitat-parsed.env ] && source /etc/habitat-parsed.env
S="/usr/local/bin/set-stage.sh"
LOG="/var/log/phase2.log"
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
  xfce4 xfce4-goodies xfce4-terminal elementary-xfce-icon-theme yaru-theme-gtk \
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
ExecStart=/bin/bash -c 'echo \$\$ > /tmp/xvfb.pid && exec /usr/bin/Xvfb :10 -screen 0 1920x1080x24 -ac'
ExecStopPost=/bin/rm -f /tmp/xvfb.pid
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
ConditionPathExists=/var/lib/init-status/phase2-complete
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
mkdir -p $H/.config/xfce4/xfconf/xfce-perchannel-xml
# Write desktop background config BEFORE starting desktop service (fixes race condition)
if [ -n "$BG_COLOR" ] && [ ${#BG_COLOR} -eq 6 ]; then
  R=$(printf "%.5f" "$(echo "scale=5; $((16#${BG_COLOR:0:2}))/255" | bc)")
  G=$(printf "%.5f" "$(echo "scale=5; $((16#${BG_COLOR:2:2}))/255" | bc)")
  B=$(printf "%.5f" "$(echo "scale=5; $((16#${BG_COLOR:4:2}))/255" | bc)")
  cat > "$H/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" <<BGXML
<?xml version="1.0"?><channel name="xfce4-desktop" version="1.0"><property name="backdrop" type="empty"><property name="screen0" type="empty"><property name="monitorscreen" type="empty"><property name="workspace0" type="empty"><property name="color-style" type="int" value="0"/><property name="image-style" type="int" value="0"/><property name="rgba1" type="array"><value type="double" value="${R}"/><value type="double" value="${G}"/><value type="double" value="${B}"/><value type="double" value="1"/></property></property></property></property></property></channel>
BGXML
fi
chown -R $USERNAME:$USERNAME $H/.config
systemctl daemon-reload
systemctl enable xvfb desktop x11vnc
# MOVED TO END: systemctl start xvfb
# Wait for Xvfb PID file and verify process is actually Xvfb (avoids cross-shell $! race + PID reuse)
# MOVED TO END: for i in {1..30}; do
  # MOVED TO END: if [ -f /tmp/xvfb.pid ]; then
    # MOVED TO END: XVFB_PID=$(cat /tmp/xvfb.pid 2>/dev/null)
    # Verify PID exists AND process is actually Xvfb (not a recycled PID)
    # MOVED TO END: if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
      # MOVED TO END: if grep -q "Xvfb" /proc/"$XVFB_PID"/cmdline 2>/dev/null; then
        # MOVED TO END: break
      # MOVED TO END: fi
    # MOVED TO END: fi
  # MOVED TO END: fi
  # MOVED TO END: sleep 0.5
# MOVED TO END: done
# MOVED TO END: systemctl start desktop
# MOVED TO END: sleep 3
# MOVED TO END: systemctl start x11vnc
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
# Enable and run the restore service (runs before openclaw restarts)
systemctl enable openclaw-restore.service 2>/dev/null || true
systemctl start openclaw-restore.service 2>/dev/null || true
/usr/local/sbin/build-full-config.sh || {
  echo "FATAL: build-full-config.sh failed — session services may not exist" >&2
  touch /var/lib/init-status/build-failed
  # Continue with remaining setup (desktop, sync, etc.) but don't mark boot-complete later
}
systemctl enable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
systemctl enable openclaw-sync.timer 2>/dev/null || true
systemctl start openclaw-sync.timer 2>/dev/null || true
# Start desktop services now that everything is installed
systemctl start xvfb
# Wait for Xvfb PID file and verify process is actually Xvfb (avoids cross-shell $! race + PID reuse)
for _ in {1..30}; do
  if [ -f /tmp/xvfb.pid ]; then
    XVFB_PID=$(cat /tmp/xvfb.pid 2>/dev/null)
    # Verify PID exists AND process is actually Xvfb (not a recycled PID)
    if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
      if grep -q "Xvfb" /proc/"$XVFB_PID"/cmdline 2>/dev/null; then
        break
      fi
    fi
  fi
  sleep 0.5
done
systemctl start desktop
sleep 3
systemctl start x11vnc
systemctl restart xrdp
# Only mark phase2 complete if build succeeded
if [ ! -f /var/lib/init-status/build-failed ]; then
  touch /var/lib/init-status/phase2-complete
  touch /var/lib/init-status/needs-post-boot-check
else
  echo "WARNING: Skipping phase2-complete marker due to build failure" >> "$LOG"
  touch /var/lib/init-status/needs-post-boot-check
fi
GT=$(cat /home/bot/.openclaw/gateway-token.txt 2>/dev/null)
[ -n "$GT" ] && curl -sf -X POST http://localhost:18789/api/cron/wake \
  -H "Authorization: Bearer $GT" -H "Content-Type: application/json" \
  -d '{"mode":"now"}' >> "$LOG" 2>&1 || true
# Boot notification removed - health check sends final status after reboot
sleep 5
reboot
