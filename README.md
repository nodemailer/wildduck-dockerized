# Wildduck: dockerized - 🦆+🐋=❤
The default docker-compose file will set up:

| Service          | Why                                                       | 
| ---------------- | --------------------------------------------------------- | 
| WildDuck         | IMAP, POP3                                                | 
| WildDuck Webmail | Webmail, creating accounts, <br> editing account settings | 
| ZoneMTA          | Outbound smtp                                             | 
| Haraka           | Inbound smtp                                              | 
| Rspamd           | Spam filtering                                            | 
| Traefik          | Reverse proxy with automatic TLS                          | 
| MongoDB          | Database used by most services                            | 
| Redis            | Key-value store used by most services                     | 

For the default docker-compose file to work without any further setup, you need port 80/443 available for Traefik to get certificates. However, the compose file is not set in stone. You can remove Traefik from the equation and use your own reverse proxy (or configure the applications to handle TLS directly), remove certain services, etc.

No STARTTLS support, only SSL/TLS.

## Set up Docker
Install Docker:
```console
$ curl -fsSL https://get.docker.com -o get-docker.sh
$ sh get-docker.sh
```

Install docker-compose
```console
$ sudo curl -L "https://github.com/docker/compose/releases/download/1.28.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
$ sudo chmod +x /usr/local/bin/docker-compose
```

## Deploy Wildduck: dockerized
Create a new directory and run the setup docker image. The image only copies the default `config` folder, `.env`, `docker-compose.yml`, and edits them for your domain. It does not install anything on the host system.

The setup image takes 1-2 arguments. The domain for your email (e.g `example.com`), and the hostname where your mail server will be (e.g `mail.example.com`). They can be the same host, if you host your website on the same server for example.
```console
$ mkdir wildduck-dockerized
$ cd wildduck-dockerized
$ docker run --rm -v "${PWD}:/wildduck-dockerized" nodemailer/wildduck-dockerized-setup:1.0.2 domainname [hostname]
```

Optionally set your contact address in the `.env` file for lets encrypt expiry notices:
```sh
# Used as the lets encrypt contact address for expiry notices: https://letsencrypt.org/docs/expiration-emails/
ACME_EMAIL=john@example.com
```

Deploy using docker-compose:
```console
$ docker-compose up -d
```

## Custom configuration
Configuration files for all services reside in `./config`. Alter them in whichever way you want, and restart the service in question.
