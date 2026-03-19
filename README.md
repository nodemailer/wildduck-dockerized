# Wildduck: dockerized - 🦆+🐋=❤
The default `docker-compose.yml` now starts this stack:

| Service | Why |
| --- | --- |
| WildDuck | IMAP, POP3, API |
| WildDuck Webmail | Webmail and account management |
| ZoneMTA | Outbound SMTP |
| Haraka | Inbound SMTP on port 25 |
| Rspamd | Spam scoring and message classification for inbound mail |
| Traefik | TCP routing for 25 and TLS termination/routing for 443, 993, 995, and 465 |
| MongoDB | Primary database |
| Redis | Shared cache / queue state |

WildDuck and ZoneMTA are exposed as implicit TLS only through Traefik. Haraka is also published through Traefik on port 25 and can provide STARTTLS with its own certificate files.

## Quick start

1. Use `example.env` as the template for your local `.env`.
2. Set `PUBLIC_HOSTNAME`, `MAIL_DOMAIN`, and the required WildDuck secrets.
3. Set Traefik TLS mode:
   `TRAEFIK_TLS_MODE=file` and point `TRAEFIK_CERT_FILE` / `TRAEFIK_KEY_FILE` at PEM files under `./certs/`, or
   `TRAEFIK_TLS_MODE=acme` and set `TRAEFIK_CERT_RESOLVER` plus `TRAEFIK_ACME_EMAIL`.
4. If you want STARTTLS on port 25, keep Haraka's TLS files under `./certs/`.
   In `TRAEFIK_TLS_MODE=acme`, Haraka reads Traefik's issued certificate directly from the shared ACME storage. `./setup-scripts/bootstrap.sh certs` then only restarts Haraka when Traefik has renewed the certificate.
5. Start the stack with `docker compose up -d --build`.
6. Run `./setup-scripts/bootstrap.sh all` to print DNS records, ensure DKIM exists, and create the first user.

The checked-in certs under `certs/` are only suitable for local development.

## Configuration model

The compose file mounts the checked-in defaults from `default-config/` where the apps still expect a config tree, then overrides runtime settings with environment variables:

- WildDuck, ZoneMTA, and WildDuck Webmail use `APPCONF_...` variables provided by `wild-config`.
- Traefik routing and TLS are controlled from env through its file provider template in `dynamic_conf/dynamic.yml`.
- Traefik startup config is rendered by `container-scripts/traefik-entrypoint.sh`, similar to Haraka's generated runtime config flow.
- Traefik forwards all plain SMTP traffic on port `25` to Haraka with a TCP catch-all router.
- Traefik can accept incoming PROXY protocol on its public entrypoints from `TRAEFIK_PROXY_PROTOCOL_TRUSTED_IPS`.
- Traefik forwards PROXY protocol v1 to Haraka SMTP, WildDuck IMAP/POP3, and ZoneMTA submission; WildDuck Webmail stays on HTTP forwarded headers via `APPCONF_www_proxy`.
- `TRAEFIK_TLS_MODE=file` uses certificate files from the mounted `./certs` directory.
- `TRAEFIK_TLS_MODE=acme` enables a Traefik ACME resolver and router-level `certResolver`.
- Haraka is built from `docker-images/haraka/Dockerfile` and renders its runtime config from the templates under `docker-images/haraka/config`.
- The Haraka image entrypoint launches the Haraka CLI with `-c /run/haraka`, so the generated config directory is actually used.
- Haraka now talks to the bundled `rspamd` service through generated `rspamd.ini`, so inbound scanning works without shipping a static Haraka config tree.
- `smtp.ini` stays overrideable through the scalar env vars `HARAKA_SMTP_LISTEN` and `HARAKA_SMTP_NODES`.
- Haraka's `wildduck` plugin handles recipient validation and storage, so placing `rcpt_to.in_host_list` ahead of it will accept SMTP recipients before WildDuck can create the inbox delivery target.

That means you do not need `setup.sh` to bring up the default stack.

If you need more application settings, add more `APPCONF_...` entries in `docker-compose.yml`. Nested keys use underscores, for example `APPCONF_imap_setup_hostname`.

## Bootstrap helper

`setup-scripts/bootstrap.sh` is the replacement for the old `setup.sh` follow-up steps. It does not rewrite compose files or generated config trees. Instead it reads the current `.env`, waits for the API, then uses the WildDuck API directly. It requires `curl` and `node` on the host for API tasks, and `docker` for the `certs` mode.

Examples:

- `./setup-scripts/bootstrap.sh all`
- `./setup-scripts/bootstrap.sh dns`
- `./setup-scripts/bootstrap.sh dkim`
- `./setup-scripts/bootstrap.sh user`
- `./setup-scripts/bootstrap.sh certs`
- `./setup-scripts/bootstrap.sh certs --install-cron`

What it does:

- `dns` ensures a DKIM key exists for `MAIL_DOMAIN`, then writes the recommended `A/AAAA`, `MX`, `SPF`, `DKIM`, `DMARC`, and `PTR` guidance to `.bootstrap/<mail-domain>-dns.txt`
- `dkim` ensures a DKIM key exists and prints just the DKIM TXT record to `.bootstrap/<mail-domain>-dkim.txt`
- `user` creates the first mailbox through `POST /users`
- `all` runs DNS/DKIM first and then creates the first user if `FIRST_USER_*` values are configured or the shell is interactive
- `certs` syncs file-based Haraka TLS targets from Traefik and, in ACME mode, restarts Haraka only when Traefik's issued certificate changed

In `TRAEFIK_TLS_MODE=file`, `certs` copies from `TRAEFIK_CERT_FILE` / `TRAEFIK_KEY_FILE` unless Haraka already points at the same paths. In `TRAEFIK_TLS_MODE=acme`, Haraka reads Traefik's `acme.json` directly from the shared Docker volume on startup, and `certs` restarts Haraka when the certificate for `BOOTSTRAP_HARAKA_CERT_DOMAIN` or `PUBLIC_HOSTNAME` changed.

The bundled compose file mounts `./certs` as a directory into Traefik and Haraka, so Docker no longer creates PEM-named directories when the certificate files do not exist yet.

`./setup-scripts/bootstrap.sh certs --install-cron` also installs a host cron job that reruns the sync on a schedule, so Haraka picks up future Traefik renewals as well. The default schedule is `17 */12 * * *`.

Optional `.env` values for non-interactive runs are documented in `example.env`. The helper defaults to `http://127.0.0.1:${WILDDUCK_API_PORT:-8080}` and will reuse an existing DKIM key unless `BOOTSTRAP_DKIM_REPLACE=true`.

## Local hostnames

For local `.test` style development, you will usually point `PUBLIC_HOSTNAME` and `MAIL_DOMAIN` to `127.0.0.1` in your host `/etc/hosts` so the browser can reach Traefik. That breaks self-delivery from ZoneMTA, because inside the container `127.0.0.1` is the container itself, not Haraka.

Use different host-side mappings for the web hostname and the mail domain instead:

```text
127.0.0.1 mail.wildduck.dockerized.test
172.17.0.1 wildduck.dockerized.test
```

That keeps the browser path on localhost while letting ZoneMTA resolve the recipient domain back to the Docker host for SMTP on port `25`, where Traefik forwards it to Haraka.

If you change the host mappings after ZoneMTA has already tried delivery, clear the cached DNS answer and resend:

```bash
docker compose exec redis redis-cli -n 2 DEL dns:resolve_wildduck.dockerized.test_A
```

## Self-signed certificates

If you use the bundled development certs, import `certs/rootCA.pem` into your mail client or browser trust store.
