FROM ghcr.io/zone-eu/kirin:0.1.3

USER root

RUN npm install --omit=dev --ignore-scripts --no-save --package-lock=false \
      @zone-eu/kirin-plugin-rspamd@0.1.0 \
      @zone-eu/kirin-plugin-wildduck@0.1.1 \
    && npm cache clean --force

USER node
