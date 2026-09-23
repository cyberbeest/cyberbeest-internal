#!/bin/bash
# Push the report receiver to the v-server (`ssh vserver`, see ~/.ssh/config) and restart it.
set -euo pipefail
cd "$(dirname "$0")"
scp -q report-receiver.py cyberbeest-reports.service Caddyfile vserver:/tmp/
ssh vserver 'set -e
sudo install -D -m 644 /tmp/report-receiver.py /opt/cyberbeest-reports/report-receiver.py
sudo install -m 644 /tmp/cyberbeest-reports.service /etc/systemd/system/cyberbeest-reports.service
sudo install -m 644 /tmp/Caddyfile /etc/caddy/Caddyfile
rm /tmp/report-receiver.py /tmp/cyberbeest-reports.service /tmp/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || { echo "Caddyfile invalid"; exit 1; }
sudo systemctl daemon-reload
sudo systemctl restart cyberbeest-reports
sudo systemctl reload caddy
echo "receiver: $(systemctl is-active cyberbeest-reports), caddy: $(systemctl is-active caddy)"'
