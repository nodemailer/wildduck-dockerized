# WildDuck: dockerized - 🦆+🐋=❤

The default `docker-compose.yml` starts a complete WildDuck mail stack:

| Service | Purpose |
| --- | --- |
| WildDuck | IMAP, POP3, and API |
| WildDuck Webmail | Webmail and account management |
| ZoneMTA | Outbound SMTP |
| Kirin | Inbound SMTP on port 25 |
| Rspamd | Inbound spam scoring and classification |
| Traefik | Web routing, mail TLS termination, and SMTP proxying |
| MongoDB | Primary database |
| Redis | Shared cache and queue state |

WildDuck and ZoneMTA use implicit TLS through Traefik. Traefik forwards port 25 to Kirin with PROXY protocol v1, while Kirin provides STARTTLS with the certificate files mounted from `./certs`.

## Quick start

1. Copy `example.env` to `.env`.
2. Set `PUBLIC_HOSTNAME`, `MAIL_DOMAIN`, and every required WildDuck secret. Set `SMTP_HOSTNAME` too if the SMTP PTR/HELO name differs from the client-facing hostname.
3. Choose a Traefik TLS mode:
   - For local files, keep `TRAEFIK_TLS_MODE=file` and point `TRAEFIK_CERT_FILE` and `TRAEFIK_KEY_FILE` to PEM files under `./certs`.
   - For Let's Encrypt, set `TRAEFIK_TLS_MODE=acme`, `TRAEFIK_CERT_RESOLVER`, and `TRAEFIK_ACME_EMAIL`.
4. Start the stack:

   ```bash
   docker compose up -d --build
   ```

5. Create DKIM material, print the required DNS records, and optionally create the first mailbox:

   ```bash
   ./setup-scripts/bootstrap.sh all
   ```

6. In ACME mode, visit `https://$PUBLIC_HOSTNAME/` once so Traefik requests the certificate. Then export it for Kirin and install the renewal sync job:

   ```bash
   ./setup-scripts/bootstrap.sh certs --install-cron
   ```

The development certificates under `certs/` are not suitable for production.

## Kirin and its plugins

The Compose build is based on `ghcr.io/zone-eu/kirin:0.1.3`. During the image build it installs these published npm packages:

- `@zone-eu/kirin-plugin-rspamd@0.1.0`
- `@zone-eu/kirin-plugin-wildduck@0.1.1`

No Kirin or plugin source checkout is required in this repository. Rspamd runs first at ordering `50`. The WildDuck receiver runs at ordering `100` to validate recipients and store accepted messages.

Kirin is configured through `APPCONF_...` environment variables in `docker-compose.yml`. Its optional database overrides are `KIRIN_MONGO_URL` and `KIRIN_SENDER_DB`. Its STARTTLS paths are `KIRIN_TLS_CERT_FILE` and `KIRIN_TLS_KEY_FILE`.

## Runtime configuration

- WildDuck, ZoneMTA, WildDuck Webmail, and Kirin use `APPCONF_...` overrides provided by `wild-config`.
- Traefik configuration is rendered by `container-scripts/traefik-entrypoint.sh` and the file-provider template in `dynamic_conf/dynamic.yml`.
- Traefik terminates TLS for HTTPS, IMAPS, POP3S, and SMTPS. Kirin terminates STARTTLS itself on port 25.
- Traefik accepts PROXY protocol on public entrypoints only when `TRAEFIK_PROXY_PROTOCOL_TRUSTED_IPS` is explicitly set. It forwards PROXY protocol v1 to Kirin, WildDuck, and ZoneMTA.
- `SMTP_HOSTNAME` controls the SMTP identity used by Kirin and ZoneMTA. It falls back to `PUBLIC_HOSTNAME`.
- Additional nested settings can be expressed as `APPCONF_...` keys, for example `APPCONF_imap_setup_hostname`.

The default stack does not require the legacy setup generator.

## Legacy Haraka stack

The previous Haraka-based Compose workflow is isolated under `legacy-haraka/`. Run `legacy-haraka/setup.sh` to generate its configuration. Its `docker-compose-w-setup.yml`, certificate updater, and helper scripts apply only to that legacy stack.

See [`legacy-haraka/README.md`](legacy-haraka/README.md) for configuration, VPS production deployment, TLS, DNS, operation, updates, and troubleshooting.

## Bootstrap helper

`setup-scripts/bootstrap.sh` reads `.env`, waits for the WildDuck API when needed, and supports these modes:

- `all`: ensure DKIM, write DNS guidance, and create the first user when configured or interactive
- `dns`: ensure DKIM and write A/AAAA, MX, SPF, DKIM, DMARC, and PTR guidance
- `dkim`: ensure DKIM and write only the DKIM record
- `user`: create the first mailbox through the WildDuck API
- `certs`: synchronize Traefik's certificate files to Kirin and restart Kirin only when they change

Examples:

```bash
./setup-scripts/bootstrap.sh all
./setup-scripts/bootstrap.sh dns
./setup-scripts/bootstrap.sh dkim
./setup-scripts/bootstrap.sh user
./setup-scripts/bootstrap.sh certs
./setup-scripts/bootstrap.sh certs --install-cron
```

In file mode, `certs` copies from `TRAEFIK_CERT_FILE` and `TRAEFIK_KEY_FILE` unless Kirin already uses those exact paths. In ACME mode, it exports the certificate selected by `BOOTSTRAP_KIRIN_CERT_DOMAIN` (or `PUBLIC_HOSTNAME`) from Traefik's `acme.json`. The default renewal check schedule is `17 */12 * * *`.

The helper requires `curl` and `node` for API tasks, plus Docker for certificate synchronization. Optional non-interactive settings are documented in `example.env`.

## Local hostnames

Mapping both the public hostname and mail domain to `127.0.0.1` breaks local self-delivery: inside ZoneMTA, that address refers to the ZoneMTA container. Use separate host mappings, for example:

```text
127.0.0.1 mail.wildduck.dockerized.test
172.17.0.1 wildduck.dockerized.test
```

This keeps browser traffic on localhost while allowing ZoneMTA to resolve the recipient domain back to the Docker host, where Traefik forwards port 25 to Kirin.

If the mapping changes after a delivery attempt, clear ZoneMTA's cached DNS answer before retrying:

```bash
docker compose exec redis redis-cli -n 2 DEL dns:resolve_wildduck.dockerized.test_A
```

## Self-signed certificates

For local development, import `certs/rootCA.pem` into your mail client or browser trust store.
