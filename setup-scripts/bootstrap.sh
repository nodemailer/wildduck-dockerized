#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: setup-scripts/bootstrap.sh [all|dns|dkim|user|certs] [--env-file PATH] [--no-wait] [--install-cron] [--cron-schedule EXPR]

Reads the repo .env, waits for the WildDuck API, ensures DKIM exists for MAIL_DOMAIN,
prints DNS records, optionally creates the first user, and can sync Kirin TLS files
from Traefik.

Modes:
  all   Ensure DKIM, write DNS records, and create the first user if configured or interactive
  dns   Ensure DKIM and write DNS records
  dkim  Ensure DKIM and print just the DKIM TXT record
  user  Create the first user
  certs Sync Kirin TLS files from Traefik and restart Kirin if they changed

Options for certs mode:
  --install-cron         Install a recurring host cron job that reruns `bootstrap.sh certs`
  --cron-schedule EXPR   Override the cron schedule, default: BOOTSTRAP_KIRIN_CERT_CRON_SCHEDULE or `17 */12 * * *`
EOF
}

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

default_dkim_selector() {
    node -e '
const now = new Date();
process.stdout.write(now.toString().substr(4, 3).toLowerCase() + now.getFullYear());
'
}

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="all"
ENV_FILE="$REPO_ROOT/.env"
SKIP_WAIT=0
STATE_DIR="$REPO_ROOT/.bootstrap"
API_STATUS=""
API_BODY=""
API_URL=""
PUBLIC_IP=""
DKIM_SOURCE=""
DKIM_ID=""
DKIM_SELECTOR_CURRENT=""
DKIM_DNS_NAME=""
DKIM_DNS_VALUE=""
DKIM_FINGERPRINT=""
FIRST_USER_ID=""
GENERATED_PASSWORD=0
INSTALL_CERTS_CRON=""
CERTS_CRON_SCHEDULE=""

while [ $# -gt 0 ]; do
    case "$1" in
        all|dns|dkim|user|certs)
            MODE="$1"
            shift
            ;;
        --env-file)
            [ $# -ge 2 ] || die "--env-file requires a path"
            case "$2" in
                /*)
                    ENV_FILE="$2"
                    ;;
                *)
                    ENV_FILE="$REPO_ROOT/$2"
                    ;;
            esac
            shift 2
            ;;
        --no-wait)
            SKIP_WAIT=1
            shift
            ;;
        --install-cron)
            INSTALL_CERTS_CRON="1"
            shift
            ;;
        --cron-schedule)
            [ $# -ge 2 ] || die "--cron-schedule requires a cron expression"
            CERTS_CRON_SCHEDULE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

load_env() {
    [ -f "$ENV_FILE" ] || die "Env file not found: $ENV_FILE"

    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a

    : "${PUBLIC_HOSTNAME:?set PUBLIC_HOSTNAME in $ENV_FILE}"
    : "${MAIL_DOMAIN:?set MAIL_DOMAIN in $ENV_FILE}"

    if [ "$MODE" != "certs" ]; then
        : "${WILDDUCK_API_ACCESS_TOKEN:?set WILDDUCK_API_ACCESS_TOKEN in $ENV_FILE}"
    fi

    API_URL="${BOOTSTRAP_API_URL:-http://127.0.0.1:${WILDDUCK_API_PORT:-8080}}"
    DKIM_SELECTOR="${DKIM_SELECTOR:-$(default_dkim_selector)}"
    DKIM_DESCRIPTION="${DKIM_DESCRIPTION:-Bootstrap DKIM for $MAIL_DOMAIN}"
    BOOTSTRAP_WAIT_TIMEOUT="${BOOTSTRAP_WAIT_TIMEOUT:-120}"
    BOOTSTRAP_KIRIN_CERT_CRON_SCHEDULE="${BOOTSTRAP_KIRIN_CERT_CRON_SCHEDULE:-17 */12 * * *}"

    if [ -z "$INSTALL_CERTS_CRON" ] && is_true "${BOOTSTRAP_INSTALL_KIRIN_CERT_CRON:-false}"; then
        INSTALL_CERTS_CRON="1"
    fi

    if [ -z "$CERTS_CRON_SCHEDULE" ]; then
        CERTS_CRON_SCHEDULE="$BOOTSTRAP_KIRIN_CERT_CRON_SCHEDULE"
    fi

    mkdir -p "$STATE_DIR"
}

resolve_repo_path() {
    case "$1" in
        /*)
            printf '%s\n' "$1"
            ;;
        ./*)
            printf '%s\n' "$REPO_ROOT/${1#./}"
            ;;
        *)
            printf '%s\n' "$REPO_ROOT/$1"
            ;;
    esac
}

compose_cmd() {
    (
        cd "$REPO_ROOT"
        docker compose --env-file "$ENV_FILE" "$@"
    )
}

json_get() {
    local path="$1"
    JSON_PATH="$path" node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8").trim();
if (!raw) {
    process.exit(2);
}
let data;
try {
    data = JSON.parse(raw);
} catch {
    process.exit(2);
}
let value = data;
for (const segment of (process.env.JSON_PATH || "").split(".")) {
    if (!segment) {
        continue;
    }
    if (value === null || value === undefined || !(segment in value)) {
        process.exit(2);
    }
    value = value[segment];
}
if (value === null || value === undefined) {
    process.exit(2);
}
process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
'
}

json_get_or_empty() {
    local path="$1"
    local input="${2-}"
    local value

    if value="$(printf '%s' "$input" | json_get "$path" 2>/dev/null)"; then
        printf '%s' "$value"
    fi
}

urlencode() {
    VALUE="$1" node -e 'process.stdout.write(encodeURIComponent(process.env.VALUE || ""))'
}

build_dkim_payload() {
    DOMAIN="$MAIL_DOMAIN" SELECTOR="$DKIM_SELECTOR" DESCRIPTION="$DKIM_DESCRIPTION" node -e '
const payload = {
    domain: process.env.DOMAIN,
    selector: process.env.SELECTOR,
    description: process.env.DESCRIPTION
};
process.stdout.write(JSON.stringify(payload));
'
}

build_user_payload() {
    USERNAME="$FIRST_USER_NAME" PASSWORD="$FIRST_USER_PASSWORD" ADDRESS="$FIRST_USER_ADDRESS" DISPLAY_NAME="${FIRST_USER_DISPLAY_NAME:-}" node -e '
const payload = {
    username: process.env.USERNAME,
    password: process.env.PASSWORD,
    address: process.env.ADDRESS
};
if (process.env.DISPLAY_NAME) {
    payload.name = process.env.DISPLAY_NAME;
}
process.stdout.write(JSON.stringify(payload));
'
}

api_error_message() {
    local code error

    code="$(json_get_or_empty 'code' "$API_BODY")"
    error="$(json_get_or_empty 'error' "$API_BODY")"

    if [ -n "$code" ] || [ -n "$error" ]; then
        printf 'HTTP %s (%s): %s' "${API_STATUS:-unknown}" "${code:-unknown}" "${error:-unexpected API error}"
        return
    fi

    printf 'HTTP %s: %s' "${API_STATUS:-unknown}" "${API_BODY:-empty response}"
}

api_request() {
    local method="$1"
    local path="$2"
    local data="${3-}"
    local body_file

    body_file="$(mktemp)"

    if [ -n "$data" ]; then
        if ! API_STATUS="$(
            curl -sS -o "$body_file" -w '%{http_code}' \
                -X "$method" \
                -H 'Accept: application/json' \
                -H 'Content-Type: application/json' \
                -H "X-Access-Token: $WILDDUCK_API_ACCESS_TOKEN" \
                --data "$data" \
                "$API_URL$path"
        )"; then
            rm -f "$body_file"
            die "Request failed: $method $API_URL$path"
        fi
    else
        if ! API_STATUS="$(
            curl -sS -o "$body_file" -w '%{http_code}' \
                -X "$method" \
                -H 'Accept: application/json' \
                -H "X-Access-Token: $WILDDUCK_API_ACCESS_TOKEN" \
                "$API_URL$path"
        )"; then
            rm -f "$body_file"
            die "Request failed: $method $API_URL$path"
        fi
    fi

    API_BODY="$(cat "$body_file")"
    rm -f "$body_file"
}

wait_for_api() {
    local body_file
    local deadline

    if [ "$SKIP_WAIT" = "1" ]; then
        return 0
    fi

    deadline=$((SECONDS + BOOTSTRAP_WAIT_TIMEOUT))
    log "Waiting for WildDuck API at $API_URL"

    while :; do
        body_file="$(mktemp)"

        if API_STATUS="$(
            curl -sS -o "$body_file" -w '%{http_code}' \
                -X GET \
                -H 'Accept: application/json' \
                -H "X-Access-Token: $WILDDUCK_API_ACCESS_TOKEN" \
                "$API_URL/users?limit=1" 2>/dev/null
        )"; then
            API_BODY="$(cat "$body_file")"
        else
            API_STATUS="000"
            API_BODY=""
        fi

        rm -f "$body_file"

        case "$API_STATUS" in
            200)
                return 0
                ;;
            403)
                die "WildDuck API rejected WILDDUCK_API_ACCESS_TOKEN at $API_URL"
                ;;
        esac

        if [ "$SECONDS" -ge "$deadline" ]; then
            die "WildDuck API at $API_URL did not become ready within ${BOOTSTRAP_WAIT_TIMEOUT}s"
        fi

        sleep 2
    done
}

detect_public_ip() {
    if [ -n "${BOOTSTRAP_PUBLIC_IP:-}" ]; then
        PUBLIC_IP="$BOOTSTRAP_PUBLIC_IP"
        return 0
    fi

    if PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null)"; then
        return 0
    fi

    PUBLIC_IP=""
}

ensure_dkim() {
    local encoded_domain payload

    encoded_domain="$(urlencode "$MAIL_DOMAIN")"
    api_request GET "/dkim/resolve/$encoded_domain"

    case "$API_STATUS" in
        200)
            DKIM_ID="$(json_get_or_empty 'id' "$API_BODY")"
            [ -n "$DKIM_ID" ] || die "DKIM resolve succeeded but did not return an id"

            if is_true "${BOOTSTRAP_DKIM_REPLACE:-false}"; then
                payload="$(build_dkim_payload)"
                api_request POST "/dkim" "$payload"
                [ "$API_STATUS" = "200" ] || die "Unable to update DKIM for $MAIL_DOMAIN: $(api_error_message)"
                DKIM_SOURCE="updated"
            else
                api_request GET "/dkim/$DKIM_ID"
                [ "$API_STATUS" = "200" ] || die "Unable to load DKIM for $MAIL_DOMAIN: $(api_error_message)"
                DKIM_SOURCE="existing"
            fi
            ;;
        404)
            payload="$(build_dkim_payload)"
            api_request POST "/dkim" "$payload"
            [ "$API_STATUS" = "200" ] || die "Unable to create DKIM for $MAIL_DOMAIN: $(api_error_message)"
            DKIM_SOURCE="created"
            ;;
        403)
            die "WildDuck API rejected WILDDUCK_API_ACCESS_TOKEN while checking DKIM"
            ;;
        *)
            die "Unable to resolve DKIM for $MAIL_DOMAIN: $(api_error_message)"
            ;;
    esac

    DKIM_ID="$(json_get_or_empty 'id' "$API_BODY")"
    DKIM_SELECTOR_CURRENT="$(json_get_or_empty 'selector' "$API_BODY")"
    DKIM_DNS_NAME="$(json_get_or_empty 'dnsTxt.name' "$API_BODY")"
    DKIM_DNS_VALUE="$(json_get_or_empty 'dnsTxt.value' "$API_BODY")"
    DKIM_FINGERPRINT="$(json_get_or_empty 'fingerprint' "$API_BODY")"

    [ -n "$DKIM_ID" ] || die "DKIM response is missing id"
    [ -n "$DKIM_SELECTOR_CURRENT" ] || die "DKIM response is missing selector"
    [ -n "$DKIM_DNS_NAME" ] || die "DKIM response is missing dnsTxt.name"
    [ -n "$DKIM_DNS_VALUE" ] || die "DKIM response is missing dnsTxt.value"
}

generate_password() {
    node -e '
const crypto = require("crypto");
const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
let out = "";
while (out.length < 30) {
    const bytes = crypto.randomBytes(48);
    for (const byte of bytes) {
        out += chars[byte % chars.length];
        if (out.length === 30) {
            break;
        }
    }
}
process.stdout.write(out);
'
}

prepare_first_user_identity() {
    local allow_skip="${1:-0}"

    if [ -z "${FIRST_USER_NAME:-}" ] && [ -n "${FIRST_USER_ADDRESS:-}" ]; then
        if [[ "$FIRST_USER_ADDRESS" == *@* ]]; then
            FIRST_USER_NAME="${FIRST_USER_ADDRESS%@*}"
        else
            FIRST_USER_NAME="$FIRST_USER_ADDRESS"
            unset FIRST_USER_ADDRESS
        fi
    fi

    if [ -n "${FIRST_USER_NAME:-}" ] && [[ "$FIRST_USER_NAME" == *@* ]]; then
        if [ -z "${FIRST_USER_ADDRESS:-}" ]; then
            FIRST_USER_ADDRESS="$FIRST_USER_NAME"
        fi
        FIRST_USER_NAME="${FIRST_USER_NAME%@*}"
    fi

    if [ -z "${FIRST_USER_NAME:-}" ]; then
        if [ -t 0 ]; then
            read -r -p "First username [firstuser]: " FIRST_USER_NAME
            FIRST_USER_NAME="${FIRST_USER_NAME:-firstuser}"
        elif [ "$allow_skip" = "1" ]; then
            log "Skipping first user creation. Set FIRST_USER_NAME or FIRST_USER_ADDRESS in $ENV_FILE, or run bootstrap.sh user interactively."
            return 1
        else
            die "Set FIRST_USER_NAME or FIRST_USER_ADDRESS in $ENV_FILE, or run bootstrap.sh user interactively."
        fi
    fi

    if [ -z "${FIRST_USER_ADDRESS:-}" ]; then
        FIRST_USER_ADDRESS="${FIRST_USER_NAME}@${MAIL_DOMAIN}"
    elif [[ "$FIRST_USER_ADDRESS" != *@* ]]; then
        FIRST_USER_ADDRESS="${FIRST_USER_ADDRESS}@${MAIL_DOMAIN}"
    fi

    return 0
}

ensure_first_user_password() {
    GENERATED_PASSWORD=0

    if [ -n "${FIRST_USER_PASSWORD:-}" ]; then
        return 0
    fi

    if [ -t 0 ]; then
        read -r -s -p "Password for ${FIRST_USER_ADDRESS} (leave blank to generate): " FIRST_USER_PASSWORD
        printf '\n'
    fi

    if [ -z "${FIRST_USER_PASSWORD:-}" ]; then
        FIRST_USER_PASSWORD="$(generate_password)"
        GENERATED_PASSWORD=1
    fi
}

ensure_first_user() {
    local allow_skip="${1:-0}"
    local encoded_username payload existing_address

    prepare_first_user_identity "$allow_skip" || return 0

    encoded_username="$(urlencode "$FIRST_USER_NAME")"
    api_request GET "/users/resolve/$encoded_username"

    case "$API_STATUS" in
        200)
            FIRST_USER_ID="$(json_get_or_empty 'id' "$API_BODY")"
            [ -n "$FIRST_USER_ID" ] || die "User resolve succeeded but did not return an id"

            api_request GET "/users/$FIRST_USER_ID"
            [ "$API_STATUS" = "200" ] || die "Unable to load existing user $FIRST_USER_NAME: $(api_error_message)"

            existing_address="$(json_get_or_empty 'address' "$API_BODY")"
            log "First user already exists: ${existing_address:-$FIRST_USER_NAME}"
            return 0
            ;;
        404)
            ;;
        403)
            die "WildDuck API rejected WILDDUCK_API_ACCESS_TOKEN while checking users"
            ;;
        *)
            die "Unable to resolve user $FIRST_USER_NAME: $(api_error_message)"
            ;;
    esac

    ensure_first_user_password
    payload="$(build_user_payload)"
    api_request POST "/users" "$payload"
    [ "$API_STATUS" = "200" ] || die "Unable to create user $FIRST_USER_NAME: $(api_error_message)"

    FIRST_USER_ID="$(json_get_or_empty 'id' "$API_BODY")"
    log "Created first user: $FIRST_USER_ADDRESS"

    if [ "$GENERATED_PASSWORD" = "1" ]; then
        log "Generated password: $FIRST_USER_PASSWORD"
    fi
}

spf_record_value() {
    local value

    value="v=spf1 a:${PUBLIC_HOSTNAME}"
    if [ -n "$PUBLIC_IP" ]; then
        value="$value ip4:${PUBLIC_IP}"
    fi
    value="$value ~all"

    printf '%s' "$value"
}

write_dns_report() {
    local dns_file a_record_line ptr_target spf_value

    dns_file="$STATE_DIR/${MAIL_DOMAIN}-dns.txt"
    spf_value="$(spf_record_value)"

    if [ -n "$PUBLIC_IP" ]; then
        a_record_line="$PUBLIC_HOSTNAME. IN A $PUBLIC_IP"
        ptr_target="$PUBLIC_IP"
    else
        a_record_line="Set A/AAAA records so $PUBLIC_HOSTNAME resolves to this server."
        ptr_target="your server IP"
    fi

    cat >"$dns_file" <<EOF
DNS bootstrap for $MAIL_DOMAIN
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
API: $API_URL
DKIM source: $DKIM_SOURCE
DKIM selector: $DKIM_SELECTOR_CURRENT
DKIM fingerprint: ${DKIM_FINGERPRINT:-unknown}

A / AAAA
--------
$a_record_line

MX
--
$MAIL_DOMAIN. IN MX 5 $PUBLIC_HOSTNAME.

SPF
---
$MAIL_DOMAIN. IN TXT "$spf_value"

DKIM
----
$DKIM_DNS_NAME. IN TXT "$DKIM_DNS_VALUE"

DMARC
-----
_dmarc.$MAIL_DOMAIN. IN TXT "v=DMARC1; p=reject;"

PTR
---
Set the reverse DNS for $ptr_target to $PUBLIC_HOSTNAME.
EOF

    cat "$dns_file"
    log ""
    log "Saved DNS records to $dns_file"
}

write_dkim_report() {
    local dkim_file

    dkim_file="$STATE_DIR/${MAIL_DOMAIN}-dkim.txt"

    cat >"$dkim_file" <<EOF
DKIM for $MAIL_DOMAIN
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Source: $DKIM_SOURCE
Selector: $DKIM_SELECTOR_CURRENT
Fingerprint: ${DKIM_FINGERPRINT:-unknown}

$DKIM_DNS_NAME. IN TXT "$DKIM_DNS_VALUE"
EOF

    cat "$dkim_file"
    log ""
    log "Saved DKIM record to $dkim_file"
}

copy_if_changed() {
    local source_file="$1"
    local target_file="$2"
    local mode="$3"
    local target_dir temp_file=""

    target_dir="$(dirname "$target_file")"

    if ! mkdir -p "$target_dir"; then
        die "Unable to create directory for $target_file"
    fi

    if [ -d "$target_file" ]; then
        if rmdir "$target_file" 2>/dev/null; then
            log "Removed empty directory at $target_file so it can be replaced with a TLS file."
        else
            die "Target path must be a file, but is a directory: $target_file. This usually means Docker created a bind-mount directory before the certificate file existed. Remove or chown that directory and rerun bootstrap."
        fi
    elif [ -e "$target_file" ] && [ ! -f "$target_file" ]; then
        die "Target path must be a regular file: $target_file"
    fi

    if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then
        return 1
    fi

    if ! temp_file="$(mktemp "$target_dir/.bootstrap-copy.XXXXXX")"; then
        die "Unable to create a temporary file in $target_dir"
    fi

    if ! cp "$source_file" "$temp_file"; then
        rm -f "$temp_file"
        die "Unable to copy $source_file to $target_file"
    fi

    if ! chmod "$mode" "$temp_file"; then
        rm -f "$temp_file"
        die "Unable to set mode $mode on $target_file"
    fi

    if ! mv -f "$temp_file" "$target_file"; then
        rm -f "$temp_file"
        die "Unable to replace $target_file. Check the ownership and permissions of $target_dir."
    fi

    return 0
}

set_kirin_tls_permissions() {
    local cert_file="$1"
    local key_file="$2"
    local container_uid="${KIRIN_CONTAINER_UID:-1000}"
    local container_gid="${KIRIN_CONTAINER_GID:-1000}"
    local key_uid key_gid

    if [ "$(id -u)" = "0" ]; then
        chown "$container_uid:$container_gid" "$cert_file" "$key_file"
    fi

    chmod 0644 "$cert_file"
    chmod 0640 "$key_file"

    key_uid="$(stat -c '%u' "$key_file")"
    key_gid="$(stat -c '%g' "$key_file")"
    if [ "$key_uid" != "$container_uid" ] && [ "$key_gid" != "$container_gid" ]; then
        die "Kirin runs as UID:GID ${container_uid}:${container_gid}, but cannot read $key_file. Run cert sync as root or set KIRIN_CONTAINER_UID/KIRIN_CONTAINER_GID to match the container user."
    fi
}

kirin_cert_state_changed() {
    local cert_file="$1"
    local key_file="$2"
    local state_file current_state previous_state=""

    state_file="$STATE_DIR/kirin-cert-state-${PUBLIC_HOSTNAME}.sha256"
    current_state="$(CERT_FILE="$cert_file" KEY_FILE="$key_file" node - <<'EOF'
const crypto = require("crypto");
const fs = require("fs");

const hash = crypto.createHash("sha256");
hash.update(fs.readFileSync(process.env.CERT_FILE));
hash.update(Buffer.from([0]));
hash.update(fs.readFileSync(process.env.KEY_FILE));
process.stdout.write(hash.digest("hex"));
EOF
)"

    if [ -f "$state_file" ]; then
        previous_state="$(cat "$state_file")"
    fi

    if [ "$previous_state" = "$current_state" ]; then
        return 1
    fi

    printf '%s\n' "$current_state" >"$state_file"
    chmod 0600 "$state_file"
    return 0
}

restart_kirin_if_needed() {
    local kirin_container

    kirin_container="$(compose_cmd ps -q kirin | tr -d '\r')"
    if [ -n "$kirin_container" ]; then
        log "Restarting Kirin so STARTTLS picks up the updated certificate."
        compose_cmd restart kirin >/dev/null
    else
        log "Starting Kirin with the synced TLS files."
        compose_cmd up -d kirin >/dev/null
    fi
}

sync_kirin_tls_from_files() {
    local source_cert source_key target_cert target_key changed=0 state_changed=0

    source_cert="$(resolve_repo_path "${TRAEFIK_CERT_FILE:-./certs/wildduck.dockerized.test.pem}")"
    source_key="$(resolve_repo_path "${TRAEFIK_KEY_FILE:-./certs/wildduck.dockerized.test-key.pem}")"
    target_cert="$(resolve_repo_path "${KIRIN_TLS_CERT_FILE:-./certs/wildduck.dockerized.test.pem}")"
    target_key="$(resolve_repo_path "${KIRIN_TLS_KEY_FILE:-./certs/wildduck.dockerized.test-key.pem}")"

    [ -f "$source_cert" ] || die "Traefik certificate file not found: $source_cert"
    [ -f "$source_key" ] || die "Traefik key file not found: $source_key"

    if [ "$source_cert" = "$target_cert" ] && [ "$source_key" = "$target_key" ]; then
        set_kirin_tls_permissions "$target_cert" "$target_key"
        if kirin_cert_state_changed "$target_cert" "$target_key"; then
            log "Kirin shares Traefik's TLS files and the certificate state changed."
            restart_kirin_if_needed
        else
            log "Kirin already points at the same TLS files Traefik uses."
        fi
        return 0
    fi

    if copy_if_changed "$source_cert" "$target_cert" 0644; then
        changed=1
        log "Synced Kirin certificate file to $target_cert"
    fi

    if copy_if_changed "$source_key" "$target_key" 0640; then
        changed=1
        log "Synced Kirin private key file to $target_key"
    fi

    set_kirin_tls_permissions "$target_cert" "$target_key"
    if kirin_cert_state_changed "$target_cert" "$target_key"; then
        state_changed=1
    fi

    if [ "$changed" = "1" ] || [ "$state_changed" = "1" ]; then
        restart_kirin_if_needed
    else
        log "Kirin TLS files already match Traefik's file-based certificate."
    fi
}

extract_traefik_acme_files() {
    local acme_file="$1"
    local cert_out="$2"
    local key_out="$3"
    local cert_domain resolver

    cert_domain="${BOOTSTRAP_KIRIN_CERT_DOMAIN:-$PUBLIC_HOSTNAME}"
    resolver="${TRAEFIK_CERT_RESOLVER:-letsencrypt}"

    ACME_FILE="$acme_file" CERT_OUT="$cert_out" KEY_OUT="$key_out" CERT_DOMAIN="$cert_domain" TRAEFIK_ACME_RESOLVER="$resolver" node - <<'EOF'
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
        throw new Error(`Traefik ACME resolver "${resolver}" was not found in acme.json`);
    }

    const entry = store.Certificates.find(cert => {
        const main = cert && cert.domain && cert.domain.main;
        const sans = cert && cert.domain && Array.isArray(cert.domain.sans) ? cert.domain.sans : [];
        return main === domain || sans.includes(domain);
    });

    if (!entry || !entry.certificate || !entry.key) {
        throw new Error(`No certificate for "${domain}" was found in Traefik ACME storage`);
    }

    fs.writeFileSync(certOut, Buffer.from(entry.certificate, "base64"));
    fs.writeFileSync(keyOut, Buffer.from(entry.key, "base64"), { mode: 0o600 });
} catch (err) {
    console.error(err.message || String(err));
    process.exit(1);
}
EOF
}

sync_kirin_tls_from_acme() {
    local traefik_container acme_file temp_cert temp_key target_cert target_key
    local changed=0 state_changed=0

    acme_file="$(mktemp "$STATE_DIR/traefik-acme.XXXXXX.json")"
    temp_cert="$(mktemp "$STATE_DIR/traefik-cert.XXXXXX.pem")"
    temp_key="$(mktemp "$STATE_DIR/traefik-key.XXXXXX.pem")"
    target_cert="$(resolve_repo_path "${KIRIN_TLS_CERT_FILE:-./certs/wildduck.dockerized.test.pem}")"
    target_key="$(resolve_repo_path "${KIRIN_TLS_KEY_FILE:-./certs/wildduck.dockerized.test-key.pem}")"

    log "Ensuring Traefik is running before reading ACME storage."
    compose_cmd up -d traefik >/dev/null
    traefik_container="$(compose_cmd ps -q traefik | tr -d '\r')"
    [ -n "$traefik_container" ] || die "Unable to locate the Traefik container"

    if ! docker cp "$traefik_container:/data/acme.json" "$acme_file" >/dev/null 2>&1; then
        rm -f "$acme_file" "$temp_cert" "$temp_key"
        die "Unable to read /data/acme.json from the Traefik container"
    fi

    if ! extract_traefik_acme_files "$acme_file" "$temp_cert" "$temp_key"; then
        rm -f "$acme_file" "$temp_cert" "$temp_key"
        log "Traefik ACME storage does not contain a usable certificate for ${BOOTSTRAP_KIRIN_CERT_DOMAIN:-$PUBLIC_HOSTNAME} yet."
        return 0
    fi

    if copy_if_changed "$temp_cert" "$target_cert" 0644; then
        changed=1
        log "Exported Traefik ACME certificate to $target_cert"
    fi

    if copy_if_changed "$temp_key" "$target_key" 0640; then
        changed=1
        log "Exported Traefik ACME private key to $target_key"
    fi

    set_kirin_tls_permissions "$target_cert" "$target_key"
    if kirin_cert_state_changed "$target_cert" "$target_key"; then
        state_changed=1
    fi

    if [ "$changed" = "1" ] || [ "$state_changed" = "1" ]; then
        restart_kirin_if_needed
    else
        log "Kirin already matches the certificate Traefik issued."
    fi

    rm -f "$acme_file" "$temp_cert" "$temp_key"
}

sync_kirin_certs() {
    case "${TRAEFIK_TLS_MODE:-file}" in
        file)
            sync_kirin_tls_from_files
            ;;
        acme)
            sync_kirin_tls_from_acme
            ;;
        *)
            die "Unsupported TRAEFIK_TLS_MODE: ${TRAEFIK_TLS_MODE:-}"
            ;;
    esac
}

install_kirin_cert_cron_job() {
    local sync_script log_file cron_marker legacy_cron_marker cron_line existing_crontab

    require_command crontab

    sync_script="$STATE_DIR/sync-kirin-certs.sh"
    log_file="$STATE_DIR/kirin-cert-sync.log"
    cron_marker="wildduck-kirin-cert-sync"
    legacy_cron_marker="wildduck-haraka-cert-sync"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'cd %q\n' "$REPO_ROOT"
        printf 'exec %q certs --env-file %q >>%q 2>&1\n' "$SCRIPT_DIR/bootstrap.sh" "$ENV_FILE" "$log_file"
    } >"$sync_script"
    chmod +x "$sync_script"

    printf -v cron_line '%s %q # %s' "$CERTS_CRON_SCHEDULE" "$sync_script" "$cron_marker"
    existing_crontab="$(crontab -l 2>/dev/null || true)"

    {
        if [ -n "$existing_crontab" ]; then
            printf '%s\n' "$existing_crontab" |
                awk -v current="$cron_marker" -v legacy="$legacy_cron_marker" \
                    'index($0, current) == 0 && index($0, legacy) == 0'
        fi
        printf '%s\n' "$cron_line"
    } | crontab -

    log "Installed Kirin cert sync cron job: $CERTS_CRON_SCHEDULE"
    log "Runner script: $sync_script"
    log "Cron log file: $log_file"
}

main() {
    require_command node
    require_command cmp
    load_env

    if [ -n "$INSTALL_CERTS_CRON" ] && [ "$MODE" != "certs" ]; then
        die "--install-cron can only be used with certs mode"
    fi

    case "$MODE" in
        all)
            require_command curl
            wait_for_api
            ensure_dkim
            detect_public_ip
            write_dns_report
            ensure_first_user 1
            log "Open https://$PUBLIC_HOSTNAME/ in your browser."
            ;;
        dns)
            require_command curl
            wait_for_api
            ensure_dkim
            detect_public_ip
            write_dns_report
            ;;
        dkim)
            require_command curl
            wait_for_api
            ensure_dkim
            write_dkim_report
            ;;
        user)
            require_command curl
            wait_for_api
            ensure_first_user 0
            log "Open https://$PUBLIC_HOSTNAME/ in your browser."
            ;;
        certs)
            require_command docker
            sync_kirin_certs
            if [ -n "$INSTALL_CERTS_CRON" ]; then
                install_kirin_cert_cron_job
            fi
            ;;
    esac
}

main
