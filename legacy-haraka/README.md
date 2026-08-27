# Legacy Haraka deployment

This directory contains the previous Haraka-based WildDuck deployment. It is
kept for existing installations and compatibility testing. New installations
should prefer the Kirin-based Compose stack in the repository root unless they
specifically require Haraka.

The setup helper generates a standalone deployment under
`legacy-haraka/config-generated/`. Run Docker Compose from that generated
directory, not from `legacy-haraka/` itself.

## Services and ports

| Service | Purpose | Public port |
| --- | --- | --- |
| Haraka | Inbound SMTP and STARTTLS | TCP 25 |
| Traefik | Webmail HTTPS | TCP 80 and 443 |
| Traefik / ZoneMTA | Outbound submission with implicit TLS | TCP 465 |
| Traefik / WildDuck | IMAP with implicit TLS | TCP 993 |
| Traefik / WildDuck | POP3 with implicit TLS | TCP 995 |
| WildDuck API | Local administration API | `127.0.0.1:8080` only |
| MongoDB | Mail and account data | Internal only |
| Redis | Cache and queue state | Internal only |
| Rspamd | Spam filtering | Internal only |

## VPS prerequisites

Before starting, make sure that:

- the VPS has a stable public IP address;
- the provider permits both inbound and outbound SMTP on TCP 25;
- no other service is using TCP 25, 80, 443, 465, 993, or 995;
- you can create DNS records for the mail domain;
- the VPS provider can set reverse DNS/PTR for its public IP;
- Docker Engine and the Docker Compose v2 plugin are installed;
- Bash, OpenSSL, curl, jq, Node.js, base64, and cron are installed on the host.

Use the official [Docker Engine installation guide](https://docs.docker.com/engine/install/)
and [Compose plugin guide](https://docs.docker.com/compose/install/linux/) for
the VPS distribution. Do not expose the Docker daemon TCP API. Docker documents
the security implications in [Protect the Docker daemon socket](https://docs.docker.com/engine/security/protect-access/).

## DNS and firewall preparation

For a mail domain of `example.com`, hostname `mail.example.com`, and server IP
`203.0.113.10`, create at least:

```dns
mail.example.com.  IN A   203.0.113.10
example.com.       IN MX  5 mail.example.com.
```

Ask the VPS provider to configure:

```text
203.0.113.10 -> mail.example.com
```

Do not publish an AAAA record unless IPv6 is correctly routed to the VPS and
the same ports are open over IPv6. Add SPF, DKIM, and DMARC after setup using
the generated DNS guidance.

Allow inbound TCP 25, 80, 443, 465, 993, and 995 in both the provider firewall
and the host firewall. Keep 8080 private; Compose binds it to loopback.

Docker-published ports may bypass normal UFW rules. Review Docker's
[packet filtering and firewall guidance](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
and enforce public-port policy at the VPS/provider firewall or with appropriate
Docker-aware host rules.

## Generate the configuration

From the repository root:

```bash
cd legacy-haraka
./setup.sh example.com mail.example.com
```

Arguments are:

```text
./setup.sh MAIL_DOMAIN [MAIL_HOSTNAME] [full]
```

- `MAIL_DOMAIN` is the domain used in mailbox addresses, such as `example.com`.
- `MAIL_HOSTNAME` is the public server name, such as `mail.example.com`. It
  defaults to the mail domain when omitted.
- `full` additionally generates DKIM/DNS guidance, starts the stack, registers
  DKIM, and prompts for the first mailbox.

For example:

```bash
./setup.sh example.com mail.example.com full
```

The helper asks whether to generate self-signed development certificates:

- answer `Y` for local development, a temporary private test, or as a
  placeholder that will be replaced by externally managed certificates before
  the deployment is made public;
- answer `N` to use the legacy Traefik/Let's Encrypt automation.

For Let's Encrypt, the hostname's A/AAAA records must already resolve to the
VPS and TCP 443 must be publicly reachable. The stack uses the TLS-ALPN
challenge. Traefik requires both a configured resolver and a TLS router that
references it; see the official [Traefik ACME documentation](https://doc.traefik.io/traefik/https/acme/).

Let's Encrypt has rate limits. Test DNS and connectivity first, and preserve
the Traefik volume containing `acme.json` across upgrades and restarts.

For a production VPS, externally managed file certificates are the more
predictable bootstrap path because they can be issued and validated before the
mail containers are exposed. The legacy ACME automation remains available for
existing installations that already use it.

## Generated deployment

Setup creates this layout:

```text
legacy-haraka/config-generated/
├── certs/
├── config-generated/
│   ├── haraka/
│   ├── rspamd/
│   ├── wildduck/
│   ├── wildduck-webmail/
│   └── zone-mta/
├── docker-compose.yml
└── dynamic_conf/
```

The generated configuration contains private keys and application secrets.
Restrict access to it and include it in encrypted backups. Do not commit it.

There is no legacy `.env` configuration layer. Make deployment-specific edits
in the generated files before starting Compose:

| Setting | Generated location |
| --- | --- |
| Compose images, ports, and service settings | `docker-compose.yml` |
| Haraka plugins and SMTP behavior | `config-generated/haraka/` |
| Haraka connection limits and greeting | `config-generated/haraka/connection.ini` |
| Haraka WildDuck/MongoDB/Redis integration | `config-generated/haraka/wildduck.yaml` |
| Rspamd overrides | `config-generated/rspamd/` |
| WildDuck IMAP, POP3, API, and storage | `config-generated/wildduck/` |
| ZoneMTA pools and plugins | `config-generated/zone-mta/` |
| Webmail | `config-generated/wildduck-webmail/` |
| File-based Traefik TLS certificate | `dynamic_conf/dynamic.yml` |

Rerunning `setup.sh` preserves the existing generated application config, but
refreshes the generated Compose and Traefik template and may regenerate
certificates depending on the selected TLS path. Back up local changes first.

Haraka `6.0.2` includes Haraka 3.3 and requires
`config-generated/haraka/connection.ini`. The setup helper adds the file when
it is missing but does not overwrite an existing customized copy.

## Use an externally managed certificate

If certificates are issued outside Traefik, generate the deployment by choosing
the self-signed/file-certificate path, then replace these files before exposing
the stack:

```text
config-generated/certs/mail.example.com.pem
config-generated/certs/mail.example.com-key.pem
```

The `.pem` file must contain the server certificate and required intermediate
chain. Protect the private key:

```bash
chmod 600 config-generated/certs/mail.example.com-key.pem
```

After renewal, replace both files atomically and reload the TLS consumers:

```bash
cd legacy-haraka/config-generated
docker compose restart traefik haraka
```

The included `update_certs.sh` is specifically for certificates stored in the
legacy Traefik ACME volume; it is not a general Certbot renewal hook.

## Start and operate the stack

Run all Compose commands from the generated directory:

```bash
cd legacy-haraka/config-generated
docker compose config --quiet
docker compose pull
docker compose up -d
```

Check container state and startup logs:

```bash
docker compose ps
docker compose logs --tail 200 haraka traefik wildduck zonemta rspamd
```

Expected Haraka messages include:

```text
Starting up Haraka version 3.3.2
[wildduck] Database connection opened
[server] worker ... listening on ...:25
```

Expected WildDuck startup ends with:

```text
All servers started, ready to process some mail
```

Stop the containers without deleting mail data:

```bash
docker compose down
```

Do not add `--volumes` unless the MongoDB, Redis, and Traefik volumes are
intentionally being deleted and recoverable backups exist.

## Production verification

Verify the web endpoint:

```bash
curl -I https://mail.example.com/
```

Verify Haraka SMTP and STARTTLS:

```bash
openssl s_client -starttls smtp \
  -connect mail.example.com:25 \
  -servername mail.example.com
```

Verify implicit TLS endpoints:

```bash
openssl s_client -connect mail.example.com:465 -servername mail.example.com
openssl s_client -connect mail.example.com:993 -servername mail.example.com
openssl s_client -connect mail.example.com:995 -servername mail.example.com
```

Also test sending to and from an external provider. Confirm delivery, spam
scoring, DKIM signing, SPF alignment, DMARC results, and reverse DNS rather
than relying only on open-port tests.

## Updating an existing installation

Before an update, back up:

- `legacy-haraka/config-generated/`;
- the MongoDB volume;
- the Redis volume if queued state must be retained;
- the Traefik volume and ACME state;
- any separately managed certificates and renewal configuration.

Then review the Compose/image changes and run:

```bash
cd legacy-haraka/config-generated
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --since 5m
```

The template currently leaves some images unpinned, including MongoDB, Redis,
Rspamd, and WildDuck Webmail. For controlled production upgrades, pin reviewed
image versions in the generated Compose file and update them deliberately.

## Security and operational notes

- Only trusted administrators should have Docker access; Docker control is
  effectively root-level access.
- Traefik receives the Docker socket read-only so it can read service labels.
  Treat this as sensitive host access and keep Traefik patched.
- Never change the WildDuck API binding from `127.0.0.1:8080` to a public
  address without adding strong authentication and an access-control layer.
- Protect generated secrets, DKIM private keys, TLS private keys, and backups.
- Monitor disk usage, delivery queues, MongoDB, certificate expiry, container
  restarts, and mail reputation.
- Configure off-host encrypted backups and perform restore tests before relying
  on the server for production mail.

## Troubleshooting

Check for port conflicts:

```bash
sudo ss -ltnp | grep -E ':(25|80|443|465|993|995)\b'
```

Render the effective Compose configuration:

```bash
cd legacy-haraka/config-generated
docker compose config
```

Inspect a failing service:

```bash
docker compose ps -a
docker compose logs --tail 300 SERVICE_NAME
```

Common causes are incorrect A/AAAA records, blocked SMTP ports, missing PTR,
another process occupying a published port, unreadable certificate files, an
expired certificate, or an old generated Haraka config without
`connection.ini`.
