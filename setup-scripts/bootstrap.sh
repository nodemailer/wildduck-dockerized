#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: setup-scripts/bootstrap.sh [all|dns|dkim|user] [--env-file PATH] [--no-wait]

Reads the repo .env, waits for the WildDuck API, ensures DKIM exists for MAIL_DOMAIN,
prints DNS records, and optionally creates the first user.

Modes:
  all   Ensure DKIM, write DNS records, and create the first user if configured or interactive
  dns   Ensure DKIM and write DNS records
  dkim  Ensure DKIM and print just the DKIM TXT record
  user  Create the first user
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

while [ $# -gt 0 ]; do
    case "$1" in
        all|dns|dkim|user)
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
    : "${WILDDUCK_API_ACCESS_TOKEN:?set WILDDUCK_API_ACCESS_TOKEN in $ENV_FILE}"

    API_URL="${BOOTSTRAP_API_URL:-http://127.0.0.1:${WILDDUCK_API_PORT:-8080}}"
    DKIM_SELECTOR="${DKIM_SELECTOR:-$(default_dkim_selector)}"
    DKIM_DESCRIPTION="${DKIM_DESCRIPTION:-Bootstrap DKIM for $MAIL_DOMAIN}"
    BOOTSTRAP_WAIT_TIMEOUT="${BOOTSTRAP_WAIT_TIMEOUT:-120}"

    mkdir -p "$STATE_DIR"
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

main() {
    require_command curl
    require_command node
    load_env
    wait_for_api

    case "$MODE" in
        all)
            ensure_dkim
            detect_public_ip
            write_dns_report
            ensure_first_user 1
            log "Open https://$PUBLIC_HOSTNAME/ in your browser."
            ;;
        dns)
            ensure_dkim
            detect_public_ip
            write_dns_report
            ;;
        dkim)
            ensure_dkim
            write_dkim_report
            ;;
        user)
            ensure_first_user 0
            log "Open https://$PUBLIC_HOSTNAME/ in your browser."
            ;;
    esac
}

main
