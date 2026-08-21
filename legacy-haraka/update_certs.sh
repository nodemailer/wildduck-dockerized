#!/bin/bash

HOSTNAME=${HOSTNAME:-$(hostname)}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/config-generated"
ACME_PATH="$SCRIPT_DIR/acme.json"
NEW_ACME_PATH="$SCRIPT_DIR/acme.json.new"
CERT_FILE="$SCRIPT_DIR/config-generated/certs/$HOSTNAME.pem"
KEY_FILE="$SCRIPT_DIR/config-generated/certs/$HOSTNAME-key.pem"

# Get container ID for Traefik
CONTAINER_ID=$(docker ps --filter "name=traefik" --format "{{.ID}}")

if [ -z "$CONTAINER_ID" ]; then
    echo "Traefik container not running. Starting it..."

    if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
        echo "Legacy generated Compose file not found. Run $SCRIPT_DIR/setup.sh first."
        exit 1
    fi

    (cd "$COMPOSE_DIR" && docker compose up traefik -d)

    sleep 2
    CONTAINER_ID=$(docker ps --filter "name=traefik" --format "{{.ID}}")

    if [ -z "$CONTAINER_ID" ]; then
        echo "Failed to start Traefik container. Exiting."
        exit 1
    fi
fi

# Copy the acme.json file from Traefik container
docker cp "$CONTAINER_ID:/data/acme.json" "$NEW_ACME_PATH"

# Check if acme.json has changed
if [ -f "$ACME_PATH" ] && diff -q "$ACME_PATH" "$NEW_ACME_PATH" >/dev/null; then
    echo "No changes in certificates detected."
    rm "$NEW_ACME_PATH"
    exit 0
fi

# Replace the old acme.json with the new one
mv "$NEW_ACME_PATH" "$ACME_PATH"

echo "Certificate changes detected. Updating certificate files..."

# Extract the certificate
CERT=$(jq -r --arg domain "$HOSTNAME" '.letsencrypt.Certificates[] | select(.domain.main == $domain) | .certificate' "$ACME_PATH")

# Extract the private key
KEY=$(jq -r --arg domain "$HOSTNAME" '.letsencrypt.Certificates[] | select(.domain.main == $domain) | .key' "$ACME_PATH")

# Check if we actually got the certificate and key
if [ -z "$CERT" ] || [ "$CERT" == "null" ]; then
    echo "Error: Certificate for $HOSTNAME not found!"
    exit 1
fi

if [ -z "$KEY" ] || [ "$KEY" == "null" ]; then
    echo "Error: Key for $HOSTNAME not found!"
    exit 1
fi

# Create directory if it doesn't exist
mkdir -p "$(dirname "$CERT_FILE")"

# Decode and save certificate
echo "$CERT" | base64 -d > "$CERT_FILE"

# Decode and save private key
echo "$KEY" | base64 -d > "$KEY_FILE"

echo "Certificate and key updated successfully at $(date)"
