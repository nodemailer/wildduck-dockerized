#!/bin/bash

PUBLIC_IP=`curl -s https://api.ipify.org`

cwd=$(pwd)

CWD_CONFIG="$cwd/config-generated/config-generated"

NODE_PATH=`command -v node`
DKIM_SELECTOR=`$NODE_PATH -e 'console.log(Date().toString().substr(4, 3).toLowerCase() + new Date().getFullYear())'`

openssl genrsa -out "$CWD_CONFIG/$MAILDOMAIN-dkim.pem" 1024
chmod 400 "$CWD_CONFIG/$MAILDOMAIN-dkim.pem"
openssl rsa -in "$CWD_CONFIG/$MAILDOMAIN-dkim.pem" -out "$CWD_CONFIG/$MAILDOMAIN-dkim.cert" -pubout

DKIM_DNS="v=DKIM1;k=rsa;p=$(grep -v -e '^-' $CWD_CONFIG/$MAILDOMAIN-dkim.cert | tr -d "\n")"

DKIM_JSON=`DOMAIN="$MAILDOMAIN" SELECTOR="$DKIM_SELECTOR" CWD="$CWD_CONFIG" node -e 'console.log(JSON.stringify({
  domain: process.env.DOMAIN,
  selector: process.env.SELECTOR,
  description: "Default DKIM key for "+process.env.DOMAIN,
  privateKey: fs.readFileSync(process.env.CWD + "/" +process.env.DOMAIN+"-dkim.pem", "UTF-8")
}))'`

echo "
NAMESERVER SETUP
================

MX
--
Add this MX record to the $MAILDOMAIN DNS zone:

$MAILDOMAIN. IN MX 5 $HOSTNAME.

SPF
---
Add this TXT record to the $MAILDOMAIN DNS zone:

$MAILDOMAIN. IN TXT \"v=spf1 a:$HOSTNAME a:$MAILDOMAIN ip4:$PUBLIC_IP ~all\"

Or:
$MAILDOMAIN. IN TXT \"v=spf1 a:$HOSTNAME ip4:$PUBLIC_IP ~all\"
$MAILDOMAIN. IN TXT \"v=spf1 ip4:$PUBLIC_IP ~all\"

Some explanation:
SPF is basically a DNS entry (TXT), where you can define,
which server hosts (a:[HOSTNAME]) or ip address (ip4:[IP_ADDRESS])
are allowed to send emails.
So the receiver server (eg. gmail's server) can look up this entry
and decide if you(as a sender server) is allowed to send emails as
this email address.

If you are unsure, list more a:, ip4 entries, rather then fewer.

Example:
company website: awesome.com
company's email server: mail.awesome.com
company's reverse dns entry for this email server: mail.awesome.com -> 11.22.33.44

SPF record in this case would be:
awesome.com. IN TXT \"v=spf1 a:mail.awesome.com a:awesome.com ip4:11.22.33.44 ~all\"

The following servers can send emails for *@awesome.com email addresses:
awesome.com (company's website handling server)
mail.awesome.com (company's mail server)
11.22.33.44 (company's mail server's ip address)

Please note, that a:mail.awesome.com is the same as ip4:11.22.33.44, so it is
redundant. But better safe than sorry.
And in this example, the company's website handling server can also send
emails and in general it is an outbound only server.
If a website handles email sending (confirmation emails, contact form, etc).

DKIM
----
Add this TXT record to the $MAILDOMAIN DNS zone:

$DKIM_SELECTOR._domainkey.$MAILDOMAIN. IN TXT \"$DKIM_DNS\"

The DKIM .json text we added to wildduck server:
    curl -i -XPOST http://localhost:8080/dkim \\
    -H 'Content-type: application/json' \\
    -H 'X-Access-Token: $ACCESS_TOKEN' \\
    -d '$DKIM_JSON'


Please refer to the manual how to change/delete/update DKIM keys
via the REST api (with curl on localhost) for the newest version.

List DKIM keys:
    curl -H 'X-Access-Token: $ACCESS_TOKEN' -i http://localhost:8080/dkim
Delete DKIM:
    curl -H 'X-Access-Token: $ACCESS_TOKEN' -i -XDELETE http://localhost:8080/dkim/<dkim key id>

Move DKIM keys to another machine:

Save the above curl command and dns entry.
Also copy the following two files too:
$CWD_CONFIG/$MAILDOMAIN-dkim.cert
$CWD_CONFIG/$MAILDOMAIN-dkim.pem

pem: private key (guard it well)
cert: public key

DMARC
---
Add this TXT record to the $MAILDOMAIN DNS zone:

_dmarc.$MAILDOMAIN. IN TXT \"v=DMARC1; p=reject;\"

PTR
---
Make sure that your public IP has a PTR record set to $HOSTNAME.
If your hosting provider does not allow you to set PTR records but has
assigned their own hostname, then edit zone-mta/pools.toml and replace
the hostname $HOSTNAME with the actual hostname of this server.

TL;DR
-----
Add the following DNS records to the $MAILDOMAIN DNS zone:

$MAILDOMAIN. IN MX 5 $HOSTNAME.
$MAILDOMAIN. IN TXT \"v=spf1 ip4:$PUBLIC_IP ~all\"
$DKIM_SELECTOR._domainkey.$MAILDOMAIN. IN TXT \"$DKIM_DNS\"
_dmarc.$MAILDOMAIN. IN TXT \"v=DMARC1; p=reject;\"


(this text is also stored to $CWD_CONFIG/$MAILDOMAIN-nameserver.txt)" > "$CWD_CONFIG/$MAILDOMAIN-nameserver.txt"

echo ""

cat "$CWD_CONFIG/$MAILDOMAIN-nameserver.txt"

printf "\nWaiting for the server to start up...\n\n"

CURRENT_DIR=$(basename "$(pwd)")
if [ -f "docker-compose.yml" ] && [ "$CURRENT_DIR" = "config-generated" ]; then
    docker compose up -d # run docker compose if in config-generated and compose file is present
else
    cd ./config-generated/ # cd into config-generated if not in it
    docker compose up -d
    cd ../
fi

printf "Waiting for the server to start up..."
until $(curl --output /dev/null --silent --fail -H "X-Access-Token: $ACCESS_TOKEN" -H 'Content-type: application/json' http://localhost:8080/users); do
    printf '.'
    sleep 2
done
echo "."

# Ensure DKIM key
echo "Registering DKIM key for $MAILDOMAIN"
echo $DKIM_JSON

curl -i -XPOST http://localhost:8080/dkim \
-H 'Content-type: application/json' \
-H "X-Access-Token: $ACCESS_TOKEN" \
-d "$DKIM_JSON"

echo ""
echo ""


source "./setup-scripts/user_setup.sh"
