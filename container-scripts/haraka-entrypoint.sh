#!/bin/sh
set -eu

CONFIG_DIR=/run/haraka/config

write_config() {
    file_name="$1"
    file_value="$2"
    printf '%s\n' "$file_value" > "$CONFIG_DIR/$file_name"
}

mkdir -p "$CONFIG_DIR"

write_config smtp.ini "${SMTP_INI:-}"
write_config host_list "${HOST_LIST:-}"
write_config plugins "${PLUGINS:-}"
write_config rspamd.ini "${RSPAMD_INI:-}"
write_config tls.ini "${TLS_INI:-}"
write_config log.ini "${LOG_INI:-}"
write_config wildduck.yaml "${WILDDUCK_YAML:-}"

exec /app/bin/haraka -c /run/haraka
