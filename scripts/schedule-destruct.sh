#!/bin/bash
set -a;source /etc/droplet.env;set +a
[ ! -f /etc/habitat-parsed.env ]&&python3 /usr/local/bin/parse-habitat.py 2>/dev/null
[ -f /etc/habitat-parsed.env ]&&source /etc/habitat-parsed.env
M="$DESTRUCT_MINS";[ -n "$M" ]&&[ "$M" != "0" ]&&[ "$M" -gt 0 ] 2>/dev/null&&systemd-run --unit=self-destruct --on-active=${M}m /usr/local/bin/kill-droplet.sh
