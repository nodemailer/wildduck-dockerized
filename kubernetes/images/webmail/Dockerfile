# Compatibility fixes for the pinned Compose image behind HTTPS termination.
FROM nodemailer/wildduck-webmail@sha256:8db63388fe281633f7ca40fce2b600438e61bf6faa95747e86902d22fcea267b
USER root
COPY patch-runtime.cjs /usr/local/lib/webmail-patch-runtime.cjs
RUN node /usr/local/lib/webmail-patch-runtime.cjs
USER 1000:1000
