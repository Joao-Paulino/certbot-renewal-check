# check-cert-renewal

A single Bash script that validates that automatic Let's Encrypt renewal (certbot + cron) is healthy, and that the service using the certificate is serving the current one.

## What it checks

1. A `certbot renew` entry exists in cron, with a `--deploy-hook`
2. certbot ran recently (default: within the last 13 hours)
3. Recent renewal runs finished without errors
4. Remaining validity of each certificate (warning and critical thresholds)
5. The service (default `opensmtpd`) is active
6. The certificate served over SMTP STARTTLS matches the one on disk
7. Optional `certbot renew --dry-run`

Exit codes follow the Nagios convention: `0` OK, `1` WARNING, `2` CRITICAL, so it can be used from monitoring or CI.

## Usage

```bash
chmod +x check-cert-renewal.sh
sudo ./check-cert-renewal.sh            # standard checks
sudo ./check-cert-renewal.sh --dry-run  # also runs certbot renew --dry-run
```

## Configuration

All settings are optional environment variables:

| Variable | Default | Description |
|---|---|---|
| `CERTBOT_BIN` | `/opt/certbot_venv/bin/certbot` | Path to certbot |
| `SERVICE_NAME` | `opensmtpd` | systemd unit to check |
| `LE_DIR` | `/etc/letsencrypt` | Let's Encrypt directory |
| `LE_LOG_DIR` | `/var/log/letsencrypt` | certbot log directory |
| `WARN_DAYS` | `21` | Warn if fewer days remain |
| `CRIT_DAYS` | `7` | Critical if fewer days remain |
| `MAX_RUN_AGE_H` | `13` | Max hours since the last certbot run |
| `SMTP_HOST` | `127.0.0.1` | Host for the served-certificate check |
| `SMTP_PORT` | `25` | STARTTLS port, `0` to skip |
| `RUNS_TO_CHECK` | `5` | Recent log files scanned for errors |

Example for a different service:

```bash
sudo SERVICE_NAME=postfix SMTP_PORT=587 ./check-cert-renewal.sh
```

## Notes

- Let's Encrypt uses ARI (ACME Renewal Information), so the renewal date is a window suggested per certificate, roughly 30 days before expiry. The script prints the suggested window when it appears in the logs.
- `certbot renew --dry-run` validates the ACME flow but does not run deploy hooks. That is why check 6 compares the served certificate with the one on disk after a real renewal.
- Run as root: certbot logs and private material live under `/etc/letsencrypt` and `/var/log/letsencrypt`.

## Scheduling (optional)

```cron
30 6 * * * root /usr/local/bin/check-cert-renewal.sh >> /var/log/cert-renewal-check.log 2>&1
```

## License

MIT, see [LICENSE](LICENSE).
