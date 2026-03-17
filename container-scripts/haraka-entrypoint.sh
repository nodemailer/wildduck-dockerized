#!/bin/sh
set -eu

CONFIG_DIR=/run/haraka/config
TLS_DIR=/run/haraka/tls
TRAEFIK_ACME_FILE=/traefik-data/acme.json

log() {
    printf '%s\n' "$*" >&2
}

write_config() {
    file_name="$1"
    file_value="$2"
    printf '%s\n' "$file_value" > "$CONFIG_DIR/$file_name"
}

strip_tls_plugin() {
    awk '
    {
        trimmed = $0
        sub(/^[[:space:]]+/, "", trimmed)
        sub(/[[:space:]]+$/, "", trimmed)
        if (tolower(trimmed) != "tls") {
            print $0
        }
    }'
}

strip_tls_paths() {
    awk '
    {
        trimmed = $0
        sub(/^[[:space:]]+/, "", trimmed)
        lower = tolower(trimmed)
        if (lower ~ /^(key|cert)[[:space:]]*=/) {
            next
        }
        print $0
    }'
}

resolve_container_cert_path() {
    path_value="$1"
    mount_dir="$2"

    case "$path_value" in
        "$mount_dir"/*)
            printf '%s\n' "$path_value"
            ;;
        ./certs/*)
            printf '%s/%s\n' "$mount_dir" "${path_value#./certs/}"
            ;;
        certs/*)
            printf '%s/%s\n' "$mount_dir" "${path_value#certs/}"
            ;;
        *)
            return 1
            ;;
    esac
}

extract_traefik_acme_tls() {
    cert_domain="${BOOTSTRAP_HARAKA_CERT_DOMAIN:-${PUBLIC_HOSTNAME:-}}"
    resolver="${TRAEFIK_CERT_RESOLVER:-letsencrypt}"

    [ -n "$cert_domain" ] || return 1
    [ -f "$TRAEFIK_ACME_FILE" ] || return 1

    ACME_FILE="$TRAEFIK_ACME_FILE" CERT_OUT="$TLS_DIR/tls_cert.pem" KEY_OUT="$TLS_DIR/tls_key.pem" CERT_DOMAIN="$cert_domain" TRAEFIK_ACME_RESOLVER="$resolver" node - <<'EOF' >/dev/null
const fs = require("fs");

const acmeFile = process.env.ACME_FILE;
const certOut = process.env.CERT_OUT;
const keyOut = process.env.KEY_OUT;
const domain = process.env.CERT_DOMAIN;
const resolver = process.env.TRAEFIK_ACME_RESOLVER;

try {
    const raw = fs.readFileSync(acmeFile, "utf8").trim();
    const data = raw ? JSON.parse(raw) : {};
    const store = data[resolver];

    if (!store || !Array.isArray(store.Certificates)) {
        process.exit(1);
    }

    const entry = store.Certificates.find(cert => {
        const main = cert && cert.domain && cert.domain.main;
        const sans = cert && cert.domain && Array.isArray(cert.domain.sans) ? cert.domain.sans : [];
        return main === domain || sans.includes(domain);
    });

    if (!entry || !entry.certificate || !entry.key) {
        process.exit(1);
    }

    fs.writeFileSync(certOut, Buffer.from(entry.certificate, "base64"));
    fs.writeFileSync(keyOut, Buffer.from(entry.key, "base64"), { mode: 0o600 });
} catch {
    process.exit(1);
}
EOF
}

write_tls_ini() {
    cert_path="$1"
    key_path="$2"
    extra_tls_ini="$(printf '%s\n' "${TLS_INI:-}" | strip_tls_paths)"

    {
        printf 'key=%s\n' "$key_path"
        printf 'cert=%s\n' "$cert_path"
        if [ -n "$extra_tls_ini" ]; then
            printf '%s\n' "$extra_tls_ini"
        fi
    } > "$CONFIG_DIR/tls.ini"
}

mkdir -p "$CONFIG_DIR"
mkdir -p "$TLS_DIR"

plugins_value="${PLUGINS:-}"
tls_cert=""
tls_key=""

if [ "${TRAEFIK_TLS_MODE:-file}" = "acme" ] && extract_traefik_acme_tls; then
    tls_cert="$TLS_DIR/tls_cert.pem"
    tls_key="$TLS_DIR/tls_key.pem"
    log "Haraka STARTTLS is using the certificate from Traefik ACME storage."
else
    fallback_cert="$(resolve_container_cert_path "${HARAKA_TLS_CERT_FILE:-./certs/wildduck.dockerized.test.pem}" /app/certs 2>/dev/null || true)"
    fallback_key="$(resolve_container_cert_path "${HARAKA_TLS_KEY_FILE:-./certs/wildduck.dockerized.test-key.pem}" /app/certs 2>/dev/null || true)"

    if [ -n "$fallback_cert" ] && [ -n "$fallback_key" ] && [ -f "$fallback_cert" ] && [ -f "$fallback_key" ]; then
        tls_cert="$fallback_cert"
        tls_key="$fallback_key"
        if [ "${TRAEFIK_TLS_MODE:-file}" = "acme" ]; then
            log "Traefik ACME certificate is not available yet. Haraka STARTTLS is using the fallback TLS files."
        fi
    else
        plugins_value="$(printf '%s\n' "$plugins_value" | strip_tls_plugin)"
        log "No usable TLS certificate was found for Haraka. STARTTLS is disabled until a certificate is available."
    fi
fi

write_config smtp.ini "${SMTP_INI:-}"
write_config host_list "${HOST_LIST:-}"
write_config plugins "$plugins_value"
write_config rspamd.ini "${RSPAMD_INI:-}"
if [ -n "$tls_cert" ] && [ -n "$tls_key" ]; then
    write_tls_ini "$tls_cert" "$tls_key"
else
    write_config tls.ini "$(printf '%s\n' "${TLS_INI:-}" | strip_tls_paths)"
fi
write_config log.ini "${LOG_INI:-}"
write_config wildduck.yaml "${WILDDUCK_YAML:-}"

exec /app/bin/haraka -c /run/haraka
