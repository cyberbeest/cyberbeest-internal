# vserver

Services on the Cyberbeest v-server (netcup, Debian 13). Reach it through an
`ssh vserver` alias in `~/.ssh/config`; the host and port aren't kept here.

## reports/

Receiver for the opt-in failure reports sent by provisioning's
`lib/cyberbeest-send-report.py` ("Send Report..." in run-gui).

- Caddy terminates HTTPS for `reports.cyberbeest.com` (automatic Let's
  Encrypt certificate) and proxies to `report-receiver.py` on
  127.0.0.1:8181. The Caddyfile has no `log` directive, so there are no
  access logs.
- The receiver stores each report as
  `/var/lib/cyberbeest-reports/<date>/<time>-<random>.txt`. It never writes
  sender IPs; the rate limiter keeps a salted hash in memory only.
- Limits: 64 KB per report, 5 reports per sender per hour, 200 MB in total.

Deploy changes with `reports/deploy.sh`.

Set up DNS before starting Caddy on a new name: `cyberbeest.com` has a
wildcard record that points unknown subdomains at the webhosting server, and
Let's Encrypt blocks a name for an hour after 5 failed validations.
