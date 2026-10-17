# WildDuck on Kubernetes

This setup translates the current Compose stack into a reusable Kustomize base,
a production overlay with `mail.example.com` placeholders, and a disposable kind overlay.
It follows the [SIG CLI Kustomize base/overlay conventions](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/).
Run commands from the repository root.

## Architecture and prerequisites

Traefik exposes TCP ports 25, 80, 443, 465, 993, and 995. It terminates HTTPS and
implicit mail TLS, and sends PROXY protocol v1 to the mail backends. Kirin offers
SMTP STARTTLS using the same cert-manager TLS Secret. Backend containers listen
on unprivileged ports; Services retain the Compose port numbers. The WildDuck API
is a ClusterIP Service with no public route. Administration uses port forwarding.

Use Kubernetes 1.34+, kubectl with Kustomize v5+, Helm 3, a NetworkPolicy-capable
CNI, and a LoadBalancer implementation that supports raw TCP and preserves client
IPs. The `/` and `@` characters in plugin environment variable names require
[relaxed environment variable validation](https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/).
Traefik runs in the `traefik` namespace; NetworkPolicies depend on that name.

Reserve a public ingress IP and a stable outbound SNAT/egress IP. Configure PTR,
SMTP HELO, SPF and MX consistently, and confirm the provider permits outbound
port 25. Ingress `externalTrafficPolicy: Local` does not assign an outbound IP.
Publish A/AAAA only for working address families, and allow ports 80/443 for ACME.
HTTP-01 validation must reach Traefik from the public internet.

The bundled MongoDB and Redis StatefulSets are **single-node persistence**, with
100Gi/10Gi retained PVCs, respectively. They are not database HA. Before using
this for an availability-critical service, supply a managed MongoDB replica set
and an HA Redis endpoint, or deploy them through database operators. Do not scale
the supplied database StatefulSets: they do not configure replication or failover.
For external databases, remove `mongo.yaml`/`redis.yaml` and their PDBs from a
private base, change the connection URLs, and also update Kirin's Redis host/port
and Rspamd's `redis.conf`. Redis Cluster is unsuitable because this stack uses
logical databases 2–5. Redis remains passwordless as in Compose, protected by
NetworkPolicies; adding Redis authentication requires configuring all clients.

Choose a CSI StorageClass with expandable, encrypted volumes, topology-aware
provisioning and a suitable reclaim policy. PVCs use the default StorageClass;
set `spec.volumeClaimTemplates[].spec.storageClassName` with overlay patches to
choose another. Size resources and disks from measured mail volume. Retained PVCs
are not backups: schedule encrypted MongoDB backups/PITR and Redis backups, copy
them off cluster, and rehearse restores with the application encryption secrets.

MongoDB 8 has a [documented kernel incompatibility](https://www.mongodb.com/docs/v8.0/release-notes/8.0/)
on Linux 6.19 through 7.0.13. The production image is 8.0.30; use compatible worker
kernels. The kind overlay uses MongoDB 7.0.40 for local testing on affected hosts.
Never downgrade an existing MongoDB data volume between major versions.

## Build and configure

Kubernetes does not build images. Build the Kirin image containing the Compose
plugins and the webmail derivative fixing its nested environment parsing and
enforcing Secure session cookies behind Traefik's HTTPS termination:

```bash
docker build -t wildduck-kirin:0.1.3 kubernetes/images/kirin
docker build -t wildduck-webmail:production kubernetes/images/webmail
```

For production, push both images to your registry, then add `newName` and `digest`
entries to `overlays/production/kustomization.yaml`. The stock WildDuck and ZoneMTA
images are already pinned by digest. Pin the remaining version-tagged images to
tested digests in your release process. Configure `imagePullSecrets` if required.
The Kirin plugin build currently reports npm audit vulnerabilities, including
critical findings; review and remediate its dependency tree before public rollout.
The webmail upstream image also uses an older Alpine/Node runtime; refreshing
that application image is part of production image maintenance.

Edit `overlays/production/config.env` and `pools.toml` together. The pool name is
the SMTP HELO name and must match `SMTP_HOSTNAME` and the outbound IP's PTR.
Generate a private credential file, optionally importing the four existing shared
secrets from `.env.prod` for migration:

```bash
node kubernetes/prepare-secrets.mjs .env.prod
```

Omit `.env.prod` for fresh shared secrets. The helper generates authenticated
MongoDB URLs and additional TOTP/session secrets, creates a mode-0600 file and
refuses to overwrite an existing file. Alternatively fill in `secrets.env.example`.
The output is ignored by Git. Existing encrypted DKIM/TOTP data requires its
original encryption secret; changing these values can make existing data unreadable.
MongoDB users are initialized only on an empty PVC: editing env passwords later
does not change database user passwords. Rotate them through MongoDB as well.

Kustomize hashes ConfigMaps/Secrets, so changed values roll out referencing Pods.
Rendered output contains base64 secrets: treat it as sensitive. Enable etcd
encryption and restrict Secret/RBAC access; base64 is not encryption. For GitOps,
replace the local secret generator with your encrypted or external Secret workflow.

## Install platform controllers and deploy

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo add jetstack https://charts.jetstack.io
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update
helm upgrade --install traefik traefik/traefik --version 41.2.0 \
  --namespace traefik --create-namespace -f kubernetes/platform/traefik-values.yaml --wait
helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.1 \
  --namespace cert-manager --create-namespace -f kubernetes/platform/cert-manager-values.yaml --wait
kubectl apply -f kubernetes/overlays/production/namespace.yaml
helm upgrade --install reloader stakater/reloader --version 2.2.18 \
  --namespace wildduck -f kubernetes/platform/reloader-values.yaml --wait
kubectl apply --dry-run=server -k kubernetes/overlays/production
kubectl diff -k kubernetes/overlays/production
kubectl apply -k kubernetes/overlays/production
kubectl -n wildduck wait --for=condition=Ready certificate/wildduck-tls --timeout=10m
kubectl -n wildduck get pods,pvc
```

`kubectl diff` exits 1 when differences exist. Dry-run requires an existing namespace
and installed CRDs/controllers. cert-manager replaces Compose's `acme.json` and
host certificate cron. [Reloader](https://github.com/stakater/Reloader) restarts
Kirin when `wildduck-tls` changes because Kirin loads certificates at startup;
Traefik watches the TLS Secret itself. Without Reloader, manually restart Kirin
after every renewal. Do not run Compose `bootstrap.sh certs` for Kubernetes.

If an upstream load balancer sends PROXY protocol, set only its exact trusted
CIDRs on Traefik entrypoints. The supplied settings expect ordinary TCP. Avoid
HTTP-only cloud load balancers for mail ports. Configure provider-specific static
IP annotations on the Traefik Service in `platform/traefik-values.yaml`.

## DKIM and first mailbox

The existing bootstrap helper remains useful through a local API forward:

```bash
kubectl -n wildduck port-forward service/wildduck 8080:8080
# In another terminal; .env.prod must use the same API token as secrets.env:
BOOTSTRAP_API_URL=http://127.0.0.1:8080 BOOTSTRAP_PUBLIC_IP=YOUR_OUTBOUND_IPV4 \
  ./setup-scripts/bootstrap.sh all --env-file .env.prod
```

Publish the resulting DKIM TXT record. Check DNS guidance carefully if ingress
and outbound IPs differ: A/MX address ingress, SPF/PTR describe outbound delivery.
The helper's default IP detection identifies the operator machine, so supply
`BOOTSTRAP_PUBLIC_IP` explicitly. Create mailboxes only through authorized API access;
public self-registration is disabled.

## Local kind smoke test

This uses disposable credentials and a self-signed certificate in `wildduck-kind`.
It does not require `overlays/production/secrets.env` or public DNS. Use a dedicated
cluster; kind's default CNI does not enforce NetworkPolicies, so this verifies
application routing and startup, not network isolation or production ACME.

```bash
kind create cluster --name wildduck-test
kind load docker-image --name wildduck-test wildduck-kirin:0.1.3 wildduck-webmail:production
# Install Traefik and cert-manager using the Helm commands above in this cluster.
kubectl apply -f kubernetes/overlays/kind/namespace.yaml
kubectl apply -k kubernetes/overlays/kind
kubectl -n wildduck-kind wait --for=condition=Ready certificate/wildduck-tls --timeout=5m
kubectl -n wildduck-kind wait --for=condition=Ready pod --all --timeout=5m
smoke_code="$(< kubernetes/smoke-test.cjs)"
kubectl -n wildduck-kind exec deployment/wildduck -- node -e "$smoke_code"
kubectl -n traefik port-forward service/traefik 8443:443
# In another terminal:
curl -k --resolve mail.example.invalid:8443:127.0.0.1 https://mail.example.invalid:8443/
# When finished:
kind delete cluster --name wildduck-test
```

The smoke test checks HTTPS and Secure session cookies, IMAPS/POP3S greetings,
creates and deletes a temporary mailbox, verifies SMTPS AUTH,
delivers one message through SMTP STARTTLS/Kirin/Rspamd, and checks the INBOX via
the API. Certificate verification is disabled only in this disposable test.

## Operations

Stateless workloads use two replicas, graceful termination, topology spreading,
probes, resource requests/limits and PDBs. Single-instance MongoDB/Redis/ZoneMTA PDBs
block voluntary eviction: plan maintenance explicitly; they do not prevent crashes
or controller rolling updates. ZoneMTA uses its stable StatefulSet Pod name as
`queue.instanceId`. Scale it only after verifying queue ownership and outbound IP
behavior. Long-lived IMAP sessions may disconnect during rollouts; clients reconnect.

Default-deny ingress allows only documented application paths. Egress is intentionally
unrestricted because mail delivery, DNS/RBL lookups and remote maps need outside
access. Add CNI-specific egress controls for your infrastructure. Restrict namespace
write access because labels can grant access to internal Services. Add explicit
monitoring NetworkPolicies before scraping WildDuck's internal `/metrics` endpoint.

Monitor queue age/depth, delivery failures, authentication failures, certificate
expiry, database health, PVC free space and restarts. TCP liveness checks avoid
restarting Pods for dependency outages; WildDuck readiness checks authenticated API
access. SMTP probes establish a TCP connection only; use mail delivery monitoring
to verify the complete pipeline. Logs go to stdout; collect them centrally with
appropriate retention and access controls. Do not expose Rspamd's controller or
Traefik's dashboard publicly.

Back up and restore MongoDB/Redis before migrating Compose data. This setup creates
new PVCs; it does not move existing Compose volumes. Never delete the `wildduck`
namespace as an upgrade step. Inspect and remove obsolete hashed Secrets/ConfigMaps
only after retained ReplicaSets no longer need them; do not use broad apply pruning
against cert-manager's generated Secrets.
