
FROM alpine:3

RUN apk add --no-cache tini

RUN apk add --no-cache rspamd rspamd-controller rspamd-proxy rspamd-fuzzy ca-certificates curl

EXPOSE 11332/tcp 11333/tcp 11334/tcp

ENTRYPOINT ["/sbin/tini", "--", "/usr/sbin/rspamd"]
CMD ["-i", "-f"]