FROM node:lts-alpine as builder

ARG version=2.8.27
ARG plugin_version=1.29.9

RUN apk add --no-cache git python make g++

WORKDIR /app

RUN git clone https://github.com/haraka/Haraka.git ./ --branch ${version}
RUN npm install --production
RUN npm install haraka-plugin-wildduck@${plugin_version}


FROM node:lts-alpine as app

ENV NODE_ENV production

RUN apk add --no-cache tini openssl

WORKDIR /app
COPY --from=builder /app /app

ENTRYPOINT ["/sbin/tini", "--", "node", "haraka.js"]
