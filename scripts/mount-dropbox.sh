#!/bin/bash
mkdir -p "$HOME/Dropbox";fusermount -uz "$HOME/Dropbox" 2>/dev/null||true
rclone mount dropbox: "$HOME/Dropbox" --vfs-cache-mode writes --daemon
sleep 2&&thunar "$HOME/Dropbox"
