#!/bin/bash

args=("$@")

if [ "$#" -gt "0" ]
  then
    # foo/bar -> bar
    MAILDOMAIN=${args[0]}
    HOSTNAME=${args[1]:-$MAILDOMAIN}
    echo -e "DOMAINNAME: $MAILDOMAIN, HOSTNAME: $HOSTNAME"
  else
    echo -e "Got ZERO arguments, please read the readme for help."
    exit
fi

if [ ! -d /wildduck-dockerized/config ]; then
  echo "Copying default configuration"
  cp -r /setup/default-config /wildduck-dockerized/config
fi
if [ ! -e /wildduck-dockerized/docker-compose.yml ]; then
  echo "Copying default docker-compose.yml"
  cp -r /setup/docker-compose.yml /wildduck-dockerized/docker-compose.yml
fi
if [ ! -e /wildduck-dockerized/.env ]; then
  echo "Copying default .env"
  cp -r /setup/example.env /wildduck-dockerized/.env
fi


echo "Replacing domains in configuration"

# Zone-MTA
sed -i "s/# name=\"example.com\"/name=\"$HOSTNAME\"/" /wildduck-dockerized/config/zone-mta/pools.toml
sed -i "s/hostname=\"example.com\"/hostname=\"$HOSTNAME\"/" /wildduck-dockerized/config/zone-mta/plugins/wildduck.toml
sed -i "s/rewriteDomain=\"example.com\"/rewriteDomain=\"$MAILDOMAIN\"/" /wildduck-dockerized/config/zone-mta/plugins/wildduck.toml

# Wildduck
sed -i "s/hostname=\"example.com\"/hostname=\"$HOSTNAME\"/" /wildduck-dockerized/config/wildduck/imap.toml
sed -i "s/hostname=\"example.com\"/hostname=\"$HOSTNAME\"/" /wildduck-dockerized/config/wildduck/pop3.toml
sed -i "s/hostname=\"example.com\"/hostname=\"$HOSTNAME\"/" /wildduck-dockerized/config/wildduck/default.toml
sed -i "s/localhost:3000/$HOSTNAME/" /wildduck-dockerized/config/wildduck/default.toml
sed -i "s/#emailDomain=\"mydomain.info\"/emailDomain=\"$MAILDOMAIN\"/" /wildduck-dockerized/config/wildduck/pop3.toml

# Wildduck-webmail
sed -i "s/domain=\"localhost\"/domain=\"$MAILDOMAIN\"/" /wildduck-dockerized/config/wildduck-webmail/default.toml
sed -i "s/domains=\[\"localhost\"\]/domains=\[\"$MAILDOMAIN\"\]/" /wildduck-dockerized/config/wildduck-webmail/default.toml
sed -i "s/#appId=\"https:\/\/127.0.0.1:8080\"/appId=\"https:\/\/$MAILDOMAIN\"/" /wildduck-dockerized/config/wildduck-webmail/default.toml
sed -i "s/hostname=\"localhost\"/hostname=\"$HOSTNAME\"/g" /wildduck-dockerized/config/wildduck-webmail/default.toml

# Haraka
echo "$HOSTNAME" > /wildduck-dockerized/config/haraka/me

# Traefik
sed -i "s/HOSTNAMES=example.com/HOSTNAMES=$HOSTNAME/" /wildduck-dockerized/.env



echo "Generating secrets and placing them in configuration"

SRS_SECRET=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`
ZONEMTA_SECRET=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`
WEBMAIL_SECRET=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`
WEBMAIL_TOTP_SECRET=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`

# Zone-MTA
sed -i "s/secret=\"super secret value\"/secret=\"$ZONEMTA_SECRET\"/" /wildduck-dockerized/config/zone-mta/plugins/loop-breaker.toml
sed -i "s/secret=\"secret value\"/secret=\"$SRS_SECRET\"/" /wildduck-dockerized/config/zone-mta/plugins/wildduck.toml

# Wildduck
sed -i "s/#loopSecret=\"secret value\"/loopSecret=\"$SRS_SECRET\"/" /wildduck-dockerized/config/wildduck/sender.toml

# Wildduck-webmail
sed -i "s/secret=\"a cat\"/secret=\"$WEBMAIL_SECRET\"/" /wildduck-dockerized/config/wildduck-webmail/default.toml
sed -i "s/secret=\"a secret cat\"/secret=\"$WEBMAIL_TOTP_SECRET\"/" /wildduck-dockerized/config/wildduck-webmail/default.toml

# Haraka
sed -i "s/#loopSecret=\"secret value\"/loopSecret=\"$SRS_SECRET\"/" /wildduck-dockerized/config/haraka/wildduck.yaml


echo "Done!"