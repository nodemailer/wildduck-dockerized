FROM alpine:3

RUN apk add --no-cache bash

COPY ./ /setup

ENTRYPOINT [ "/setup/setup.sh" ]