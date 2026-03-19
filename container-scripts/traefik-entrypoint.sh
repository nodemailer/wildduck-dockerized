#!/bin/sh
set -eu

repo_cert_to_container_path() {
    case "$1" in
        /etc/traefik/certs/*)
            printf '%s\n' "$1"
            ;;
        ./certs/*)
            printf '/etc/traefik/certs/%s\n' "${1#./certs/}"
            ;;
        certs/*)
            printf '/etc/traefik/certs/%s\n' "${1#certs/}"
            ;;
        *)
            printf 'Error: TRAEFIK_CERT_FILE and TRAEFIK_KEY_FILE must point inside ./certs when using the bundled compose file.\n' >&2
            exit 1
            ;;
    esac
}

entrypoint_proxy_protocol_block() {
    indent="$1"
    trusted_ips="$2"
    [ -n "$trusted_ips" ] || return 0

    printf 'proxyProtocol:\n'
    printf '%s  trustedIPs:\n' "$indent"
    printf '%s' "$trusted_ips" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk -v indent="$indent" 'NF { printf "%s    - %s\n", indent, $0 }'
}

export TRAEFIK_CERT_CONTAINER_FILE="$(repo_cert_to_container_path "$TRAEFIK_CERT_FILE")"
export TRAEFIK_KEY_CONTAINER_FILE="$(repo_cert_to_container_path "$TRAEFIK_KEY_FILE")"

cat >/tmp/traefik.yml <<EOF
entryPoints:
  smtp:
    address: ":25"
    $(entrypoint_proxy_protocol_block "    " "${TRAEFIK_PROXY_PROTOCOL_TRUSTED_IPS:-}")
  web:
    address: ":80"
    $(entrypoint_proxy_protocol_block "    " "${TRAEFIK_PROXY_PROTOCOL_TRUSTED_IPS:-}")
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    $(entrypoint_proxy_protocol_block "    " "${TRAEFIK_PROXY_PROTOCOL_TRUSTED_IPS:-}")
  imaps:
    address: ":993"
    $(entrypoint_proxy_protocol_block "    " "${TRAEFIK_PROXY_PROTOCOL_TRUSTED_IPS:-}")
  pop3s:
    address: ":995"
    $(entrypoint_proxy_protocol_block "    " "${TRAEFIK_PROXY_PROTOCOL_TRUSTED_IPS:-}")
  smtps:
    address: ":465"
    $(entrypoint_proxy_protocol_block "    " "${TRAEFIK_PROXY_PROTOCOL_TRUSTED_IPS:-}")
providers:
  file:
    directory: /etc/traefik/dynamic_conf
    watch: true
log:
  level: "${TRAEFIK_LOG_LEVEL:-INFO}"
EOF

if [ "${TRAEFIK_TLS_MODE:-file}" = "acme" ]; then
    : "${TRAEFIK_CERT_RESOLVER:?set TRAEFIK_CERT_RESOLVER for acme mode}"
    : "${TRAEFIK_ACME_EMAIL:?set TRAEFIK_ACME_EMAIL for acme mode}"
    cat >>/tmp/traefik.yml <<EOF
certificatesResolvers:
  ${TRAEFIK_CERT_RESOLVER}:
    acme:
      email: "${TRAEFIK_ACME_EMAIL}"
      storage: /data/acme.json
      tlsChallenge: true
EOF
fi

exec traefik --configFile=/tmp/traefik.yml
