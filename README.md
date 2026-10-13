# WildDuck: dockerized - 🦆+🐋=❤

The default `docker-compose.yml` starts a complete WildDuck mail stack:

| Service | Purpose |
| --- | --- |
| WildDuck | IMAP, POP3, and API |
| WildDuck Admin | Administrator UI
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
3. Generate the administrator password hash with the published image:

   ```bash
   docker run --rm -it --entrypoint node ghcr.io/zone-eu/wildduck-admin:latest scripts/hash-password.cjs
   ```

   Paste the complete hash into `.env` as `WILDDUCK_ADMIN_PASSWORD_HASH='scrypt$...'`. The single quotes preserve the literal `$` characters. Set `WILDDUCK_ADMIN_USERNAME=yourname` to change the default login username (`admin`). Optionally set `WILDDUCK_ADMIN_SESSION_SECRET` to a persistent random secret so restarts retain login sessions.
4. Choose a Traefik TLS mode:
   - For local files, keep `TRAEFIK_TLS_MODE=file` and point `TRAEFIK_CERT_FILE` and `TRAEFIK_KEY_FILE` to PEM files under `./certs`.
   - For Let's Encrypt, set `TRAEFIK_TLS_MODE=acme`, `TRAEFIK_CERT_RESOLVER`, and `TRAEFIK_ACME_EMAIL`.
5. Start the stack:

   ```bash
   docker compose up -d --build
   ```

6. Point `admin.<MAIL_DOMAIN>` (or `WILDDUCK_ADMIN_HOSTNAME`) to your server and open `https://admin.<MAIL_DOMAIN>`. Sign in with `WILDDUCK_ADMIN_USERNAME` (default `admin`) and the password used to generate the hash. Use WildDuck Admin to create the first mailbox and DKIM keys, then publish the required mail DNS records. The optional `./setup-scripts/bootstrap.sh all` helper can also generate DKIM, print DNS guidance, and create the first mailbox.

7. In ACME mode, visit `https://$PUBLIC_HOSTNAME/` once so Traefik requests the certificate. Then export it for Kirin and install the renewal sync job:

   ```bash
   ./setup-scripts/bootstrap.sh certs --install-cron
   ```

The development certificates under `certs/` are not suitable for production.

Traefik routes the admin hostname to `wildduck-admin:8080`, using the same TLS mode as webmail. In ACME mode it requests the admin certificate automatically, in file mode the configured certificate must cover the admin hostname too. The WebAuthn origin defaults to this HTTPS hostname and secure cookies are enabled by default. For example, `PUBLIC_HOSTNAME=wildduck.email` and `MAIL_DOMAIN=wildduck.email` serve webmail at `https://wildduck.email` and admin at `https://admin.wildduck.email`. Set `WILDDUCK_ADMIN_HOSTNAME` to override the admin hostname.

The direct admin port remains bound to host loopback. To use `http://localhost:3100` instead, set `WILDDUCK_ADMIN_ORIGIN=http://localhost:3100` and `WILDDUCK_ADMIN_SECURE_COOKIES=false`. `WILDDUCK_ADMIN_PORT`, `WILDDUCK_ADMIN_USERNAME`, and `WILDDUCK_ADMIN_STRICT_2FA` are optional overrides documented in `example.env`.

## Kirin and its plugins

The Compose build is based on `ghcr.io/zone-eu/kirin:0.1.3`. During the image build it installs these published npm packages:

- `@zone-eu/kirin-plugin-rspamd@0.1.0`
- `@zone-eu/kirin-plugin-wildduck@0.1.1`

No Kirin or plugin source checkout is required in this repository. Rspamd runs first at ordering `50`. The WildDuck receiver runs at ordering `100` to validate recipients and store accepted messages.

Kirin is configured through `APPCONF_...` environment variables in `docker-compose.yml`. Its optional database overrides are `KIRIN_MONGO_URL` and `KIRIN_SENDER_DB`. Its STARTTLS paths are `KIRIN_TLS_CERT_FILE` and `KIRIN_TLS_KEY_FILE`.

## Runtime configuration

- WildDuck, WildDuck Admin, ZoneMTA, WildDuck Webmail, and Kirin use `APPCONF_...` overrides provided by `wild-config`.
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
