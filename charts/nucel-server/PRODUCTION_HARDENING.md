# Production hardening — nucel-server chart

This chart now ships several things that have to be set together in any
environment where `nucel-server` is reachable from outside the cluster:

1. A custom `arm64-general` Karpenter NodePool (so EKS Auto Mode can't
   reconcile the cluster back to amd64).
2. A persistent `NUCEL_OIDC_PRIVATE_KEY` (so OIDC tokens survive pod
   restarts). Required at install via the Helm `required` template
   function — Fix C8.
3. A persistent `NUCEL_SSH_HOST_KEY` (so SSH known-hosts pinning
   doesn't break on every restart). Fix C9.
4. A `NUCEL_METRICS_TOKEN` so `/metrics` requires `Authorization: Bearer`.
   Required at install when `prometheus.requireAuth: true` (default) —
   Fix H9.
5. HorizontalPodAutoscaler — Fix H1 (`autoscaling.enabled`).
6. PodDisruptionBudget — Fix H2 (`podDisruptionBudget.enabled`,
   on by default).
7. External Secrets Operator support — Fix H6
   (`externalSecrets.enabled`).
8. Storage class guidance for EKS (`gp3` + `WaitForFirstConsumer`) —
   Fix H7.

## Required values for production install

`helm install` / `helm upgrade` will refuse to render when any of the
values below is empty (via the Helm `required` template function).
Each is gated by a flag so dev / preview overlays can relax it
explicitly:

| Value | Gate | Why |
|-------|------|-----|
| `secrets.oidcPrivateKey` | `secrets.create=true` AND `secrets.requireProductionValues=true` (default) | Ephemeral key invalidates every issued OIDC ID token on restart and across replicas. |
| `secrets.metricsToken` | `prometheus.requireAuth=true` (default) | `/metrics` shares the public ingress; without the token, bg_job kinds + dispatch counters leak. |
| `externalSecrets.secretStoreRef.name` | `externalSecrets.enabled=true` | The ExternalSecret CRD needs a backing store. |
| `externalSecrets.remoteRef.key` | `externalSecrets.enabled=true` | The ExternalSecret needs the remote key to extract from. |

Optional but strongly recommended:

| Value | Why |
|-------|-----|
| `secrets.sshHostKey` | Without it, SSH host key rotates every pod restart; clients with `known_hosts` pinning see a MITM warning. |
| `secrets.openrouterKey` | Without it, the agent-workflow threat scanner runs in offline-mode (always returns `pass`). |
| `storage.storageClassName: gp3` (EKS) | EKS Auto Mode default is `gp2` (older AMI) or unset; `gp3` is the recommended baseline. |

### Relaxing for local dev

```yaml
secrets:
  requireProductionValues: false   # allows empty oidcPrivateKey
prometheus:
  requireAuth: false               # allows empty metricsToken
```

### Generating the required values

```bash
# OIDC Ed25519 PKCS#8 PEM (Fix C8)
openssl genpkey -algorithm ED25519 -out nucel-oidc.key

# SSH host key Ed25519 OpenSSH PEM (Fix C9)
ssh-keygen -t ed25519 -N "" -f nucel-ssh-host -C "nucel-ssh-host"

# Metrics bearer token (Fix H9)
openssl rand -base64 32 > nucel-metrics.token

helm install nucel ./charts/nucel-server \
  --set-file secrets.oidcPrivateKey=nucel-oidc.key \
  --set-file secrets.sshHostKey=nucel-ssh-host \
  --set-file secrets.metricsToken=nucel-metrics.token
```

## Why a custom NodePool

EKS Auto Mode ships two managed NodePools — `general-purpose` and
`system` — labelled `app.kubernetes.io/managed-by: eks`. Patching their
`spec.template.spec.requirements` to pin `kubernetes.io/arch=arm64`
**doesn't stick**: the EKS reconciler reverts arch overrides back to
amd64 within minutes. The supported pattern is to add your own NodePool,
which Auto Mode does not reconcile.

`charts/nucel-server/templates/nodepool-arm64.yaml` ships an
`arm64-general` pool with the same shape as the proven setup in
`conek-rails` (`infra/layers/200-addons/main.tofu`):

- `nodeClassRef` → the Auto-Mode-managed `default` NodeClass (don't
  reinvent that part)
- `requirements`:
  - `karpenter.sh/capacity-type` ∈ `[on-demand]`
  - `eks.amazonaws.com/instance-category` ∈ `[c, m, r]`
  - `eks.amazonaws.com/instance-generation` > `6` (so c7g+, c8g+, m7g+, r7g+)
  - `kubernetes.io/arch` ∈ `[arm64]`
- `limits.cpu: 100`, `limits.memory: 200Gi`

Workloads opt in via `nodeSelector: { kubernetes.io/arch: arm64 }`. We
patched all four nucel-owned deployments (`nucel-server`,
`agent-operator`, `agent-operator-webhook`, `nucel-ci-operator`) plus the
`surrealdb` StatefulSet to set this. Karpenter then provisions arm64
nodes for them via `arm64-general` instead of falling through to the
managed `general-purpose` pool.

The managed `general-purpose` pool stays untouched (so other tenants
still have it as a fallback) but our pods never schedule there because
the node selector won't match.

Toggle in `values.yaml`:

```yaml
nodePool:
  create: true              # default
  name: arm64-general
  limits:
    cpu: "100"
    memory: "200Gi"
```

## OIDC private key (`NUCEL_OIDC_PRIVATE_KEY`)

Without this set, every pod boots with an ephemeral Ed25519 key and the
log shows:

```
WARN nucel_server::oidc::keys: NUCEL_OIDC_PRIVATE_KEY not set —
  generated ephemeral Ed25519 key (tokens invalid after restart).
```

Every restart silently invalidates every previously-issued OIDC ID
token, and behind a 2-replica deployment a token signed by pod A is
rejected by pod B because they have different keys. Generate one
PKCS#8 PEM and load it into the Secret:

```bash
openssl genpkey -algorithm ED25519 -out nucel-oidc.key
kubectl -n nucel patch secret nucel-nucel-server-secrets --type=merge \
  -p="$(jq -n --rawfile k nucel-oidc.key '{stringData: {NUCEL_OIDC_PRIVATE_KEY: $k}}')"
```

`templates/deployment.yaml` already wires `NUCEL_OIDC_PRIVATE_KEY` from
the Secret behind `{{- if .Values.secrets.oidcPrivateKey }}` — set
`secrets.oidcPrivateKey` in your values overlay to populate the Secret
through the chart.

## Metrics bearer (`NUCEL_METRICS_TOKEN`)

`/metrics` is reachable from the public ingress (it shares the same
listener as the application). Without `NUCEL_METRICS_TOKEN` set, anyone
can scrape `bg_job` kinds, dispatch outcome counters, and latency
histograms — useful reconnaissance for an attacker.

When `NUCEL_METRICS_TOKEN` is set, `/metrics` requires
`Authorization: Bearer <token>`; anything else is 401. Empty/unset
keeps the endpoint open (typical for local dev).

```bash
openssl rand -base64 32 > nucel-metrics.token
kubectl -n nucel patch secret nucel-nucel-server-secrets --type=merge \
  -p="$(jq -n --rawfile t nucel-metrics.token \
    '{stringData: {NUCEL_METRICS_TOKEN: ($t | rtrimstr("\n"))}}')"
```

Then point your Prometheus scrape config at the same token:

```yaml
scrape_configs:
  - job_name: nucel-server
    bearer_token_file: /etc/prometheus/secrets/nucel-metrics-token/value
    static_configs:
      - targets: [nucel-server.nucel.svc.cluster.local:17321]
```

`templates/deployment.yaml` wires `NUCEL_METRICS_TOKEN` from the Secret
behind `{{- if .Values.secrets.metricsToken }}`; set
`secrets.metricsToken` in your values overlay to populate the Secret
through the chart.

## Prometheus auto-discovery (`prometheus.serviceMonitor`)

Fix H4 adds `templates/servicemonitor.yaml`, gated behind
`prometheus.serviceMonitor.enabled`. With the Prometheus Operator
running (kube-prometheus-stack ships it), enabling this is what
actually puts the server on the scrape target list — until then
`prometheus-rules.yaml` evaluates against an empty time-series and the
alerts can't ever fire.

```yaml
prometheus:
  alerts:
    enabled: true            # PrometheusRule (existed before)
  serviceMonitor:
    enabled: true            # new in Fix H4
    interval: 30s
    scrapeTimeout: 10s
    labels:
      release: kube-prometheus-stack   # match your Prometheus CR's selector
```

When `secrets.metricsToken` is set the ServiceMonitor automatically
wires bearer auth pulled from the chart's own Secret (no manual
`bearer_token_file` config on the Prometheus side).

**Follow-up — operator ServiceMonitor.** The `nucel-ci-operator` lives
in a different repo and ships its own manifests; its `/metrics`
endpoint (`:9091`, added in Fix H3) has a Service but no ServiceMonitor
in this chart. If you run both the server and the operator in the same
cluster, add a second ServiceMonitor in the operator's manifests
selecting `app: nucel-ci-operator` on port `http-metrics`. Keeping it
out of this chart preserves the rule that each repo owns its own
deployment surface.

## EKS: ALB ingress + IRSA service account

On EKS the chart renders against either AWS Load Balancer Controller
(ALB) or ingress-nginx — flip `ingress.className` and stamp the
controller's annotations through `ingress.annotations` (commented
examples for both live in `values.yaml`). For ALB+ACM termination set
`ingress.tls: false` (the load balancer terminates upstream); for
ingress-nginx+cert-manager leave `ingress.tls: true` and let
cert-manager populate the secret.

When the cluster has IRSA wired up (IAM OIDC provider on the EKS
control plane, IAM role with a trust policy bound to
`system:serviceaccount:<ns>:<sa>`), set
`serviceAccount.annotations."eks.amazonaws.com/role-arn"` to the role
ARN and **drop the static `repoStorage.s3.accessKeyId` /
`repoStorage.s3.secretAccessKey` from your values overlay entirely**.
The AWS SDK inside `nucel-server` will pick up the projected
service-account token via the default credentials chain and assume the
role at runtime — no long-lived IAM user, no secret rotation, and the
role's trust policy keeps the credential scoped to this exact SA in
this exact namespace.

## SSH host key (`NUCEL_SSH_HOST_KEY`) — Fix C9

`crates/nucel-server/src/ssh/mod.rs::load_or_generate_host_key` reads
the SSH server's host key from the file pointed at by
`NUCEL_SSH_HOST_KEY_PATH`. Without it the pod boots with an ephemeral
host key:

```
WARN nucel_server::ssh: NUCEL_SSH_HOST_KEY_PATH not set —
  generating ephemeral SSH host key (development mode)
```

Every restart rotates the key. Any `git clone git@nucel.dev:...` client
that has pinned the host in `~/.ssh/known_hosts` then sees the
MITM warning until the user manually re-accepts it. Multi-replica
deployments are worse — each pod's key is different, so the warning
fires on every connection routed to a different replica.

The chart now ships the key as a Secret value mounted into the pod:

```yaml
secrets:
  # OpenSSH Ed25519 PEM. Generate with:
  #   ssh-keygen -t ed25519 -N "" -f nucel-ssh-host
  sshHostKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
```

The chart mounts it at `/etc/nucel/ssh-host-key/NUCEL_SSH_HOST_KEY`
(mode `0400`) and sets `NUCEL_SSH_HOST_KEY_PATH` to that path
automatically. Volume + key are marked `optional: true` so the pod
still boots when the value is empty (ephemeral key, with the warning
above).

## Horizontal scaling (HPA) — Fix H1

Off by default; flip `autoscaling.enabled: true` to ship a
`HorizontalPodAutoscaler` against the main `nucel-server` Deployment.

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
```

CPU + memory targets only. Queue-depth driven scaling (the natural
backpressure signal for nucel-server) needs the
`nucel_bg_job_depth` Prometheus gauge exposed through
[prometheus-adapter](https://github.com/kubernetes-sigs/prometheus-adapter)
as a custom or external metric. That's a follow-up — it pulls in a
hard dependency on prometheus-adapter and requires per-cluster
metric-name configuration in the adapter ConfigMap. CPU alone is a
reasonable proxy: the Axum runtime, ingress handlers and in-process
job runner are all CPU-bound under load.

Once HPA is on, the Deployment's `spec.replicas` becomes the
*initial* replica count only; the HPA controller writes the scale
subresource from then on, so don't keep tweaking `server.replicas`.

## PodDisruptionBudget — Fix H2

On by default with `minAvailable: 1`. Keeps at least one server pod
running through voluntary disruptions (node drain, cluster upgrade,
Karpenter consolidation).

**Pair with `server.replicas >= 2`** (or `autoscaling.enabled: true`,
which defaults to `minReplicas: 2`). With a single replica
`minAvailable: 1` blocks node drains entirely — `kubectl drain` will
spin forever waiting on a non-existent second pod.

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 1       # or use maxUnavailable instead
```

## External Secrets Operator — Fix H6

When the cluster runs the
[External Secrets Operator](https://external-secrets.io) (typical on
EKS to pull from AWS Secrets Manager), flip:

```yaml
externalSecrets:
  enabled: true
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager       # your ClusterSecretStore / SecretStore name
    kind: ClusterSecretStore
  remoteRef:
    key: nucel/prod/server          # remote key whose JSON payload contains all NUCEL_* values
secrets:
  create: false                     # skip the chart-managed Secret
```

The chart renders an `ExternalSecret` (CRD from `external-secrets.io/v1beta1`)
that pulls from the remote backend and writes the rendered Secret
under the same name `deployment.yaml` references — the existing
`secretKeyRef` wiring keeps working unchanged.

The remote payload is expected to be a single JSON object whose keys
are exactly the env names the chart would set in the Secret
(`NUCEL_DB_PASS`, `NUCEL_OIDC_PRIVATE_KEY`, `NUCEL_SSH_HOST_KEY`,
`NUCEL_METRICS_TOKEN`, …). `dataFrom.extract` materialises each key
into the target Secret.

`required` template functions guard `externalSecrets.secretStoreRef.name`
and `externalSecrets.remoteRef.key` so the chart fails fast when
ExternalSecrets is enabled without both set.

When `externalSecrets.enabled: true` and `secrets.create: false`, the
`secrets.oidcPrivateKey` / `secrets.metricsToken` Helm `required` gates
no longer fire — but the *runtime* requirement is still there. The
ExternalSecret payload MUST contain those keys; otherwise the pod boots
with an ephemeral OIDC key and an open `/metrics` endpoint.

## Storage class (EKS) — Fix H7

`storage.storageClassName` defaults to empty so the chart still renders
on non-EKS clusters (it falls back to the cluster default StorageClass).

**On EKS the recommended override is `gp3`** — better IOPS, throughput,
and cost than `gp2`, which is what EKS Auto Mode falls back to on
older AMIs.

Pair it with a StorageClass that sets
`volumeBindingMode: WaitForFirstConsumer` for multi-AZ correctness —
without it the volume gets provisioned eagerly in whichever AZ the
StorageClass controller picks, and the consuming pod may then be
unschedulable across AZ boundaries.

Recommended StorageClass (install once per cluster, not from this chart):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
  fsType: ext4
```

Then in your `values.yaml` overlay:

```yaml
storage:
  storageClassName: gp3
```

The chart ships ReadWriteOnce PVCs; if a workload needs to read repos
from a pod scheduled on a different node than the writer (worker pool,
seed Job with `mountRepos: true`), switch to a ReadWriteMany class
(NFS, EFS CSI driver, Longhorn-RWX). See `values.yaml` → `worker`
comment for the pinning consequences.

## SurrealDB network isolation — audit #22

SurrealDB speaks **plaintext `ws://` on `:8000`** with no transport
encryption and no per-client authorization beyond the single
`NUCEL_DB_USER` / `NUCEL_DB_PASS` root credential. The connection string
the server uses is rendered into the ConfigMap as
`NUCEL_DB_URL: ws://surrealdb.<ns>.svc.cluster.local:8000`.

Without a NetworkPolicy, **any pod in the cluster that can route to that
Service** can open a websocket and attempt to authenticate — which means
any compromised workload (a CI runner, a noisy neighbour in a shared
cluster, an agent-workflow runner pod) can brute-force the DB credential
and read/write the entire platform's data over an unencrypted channel.

The chart ships `templates/surrealdb-networkpolicy.yaml`, gated behind
`surrealdb.networkPolicy.enabled` (off by default — it only bites on a CNI
that enforces NetworkPolicy, e.g. Calico or Cilium). It renders one of two
shapes, keyed on whether the chart owns the SurrealDB workload:

### In-chart SurrealDB (`surrealdb.deploy: true`)

An **ingress** policy on the SurrealDB pods that default-denies `:8000` and
allows it ONLY from the nucel client pods (server / worker / worker-pool /
seed / migrate — all carry the chart selector labels
`app.kubernetes.io/name=<chart>` + `app.kubernetes.io/instance=<release>`),
plus any extra peers you list under `ingress.from`:

```yaml
surrealdb:
  deploy: true
  networkPolicy:
    enabled: true
    ingress:
      from:
        # e.g. admit a backup pod in another namespace
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: nucel-backup
```

### External / managed SurrealDB (`surrealdb.deploy: false`)

This is the production default — `modules/surrealdb` (Terraform) owns the
StatefulSet, so the chart can't attach an ingress policy to pods it doesn't
manage. Instead it renders an **egress** policy on the nucel client pods
that permits DB-port egress to the endpoint(s) you list under
`externalPeers` (DNS is always allowed). With no `externalPeers` set, no
object is rendered (rather than an over-broad allow-all):

```yaml
surrealdb:
  deploy: false
  networkPolicy:
    enabled: true
    externalPeers:
      - ipBlock:
          cidr: 10.0.32.0/20      # the SurrealDB subnet / endpoint
```

> **!! READ THIS BEFORE ENABLING — the egress policy is a full default-deny
> allowlist, not a DB-port add-on. !!**
>
> A NetworkPolicy with `policyTypes: [Egress]` makes egress **default-deny**
> for every pod it selects. This policy selects the server / worker /
> worker-pool / seed / migrate pods, which need *far* more than the DB port:
> the server talks to **S3 over HTTPS:443** (`NUCEL_S3_*` wired in
> `configmap.yaml`), **SMTP**, outbound **webhooks**, the **OIDC** issuer,
> **git** remotes and container **registries**. If this policy listed only
> DNS + the DB port, enabling it standalone would **sever all of that** and
> break the platform in non-obvious ways.
>
> So the chart ships an **escape hatch**, `allowAllOtherEgress` (default
> `true`): when on, the egress policy *also* emits a broad `- {}` allow-all
> rule so non-DB egress keeps flowing. In that mode the DB-port rule is
> informational — the real control for the external case is the DB-side
> firewall (below). Turning the policy on therefore does **not** silently
> cut off S3/SMTP/etc.
>
> For a **true egress lock-down**, set `allowAllOtherEgress: false`. Then
> only DNS, the DB port and whatever you enumerate under `extraEgress`
> survive — so you **must** list every other peer the server needs:
>
> ```yaml
> surrealdb:
>   networkPolicy:
>     enabled: true
>     allowAllOtherEgress: false
>     externalPeers:
>       - ipBlock: { cidr: 10.0.32.0/20 }
>     extraEgress:
>       - ports:
>           - { protocol: TCP, port: 443 }   # S3 / OIDC / webhooks / registry
>           - { protocol: TCP, port: 587 }   # SMTP submission
>     # Optional: scope DNS to kube-dns instead of port 53 to anywhere.
>     dnsPeers:
>       - namespaceSelector:
>           matchLabels: { kubernetes.io/metadata.name: kube-system }
>         podSelector:
>           matchLabels: { k8s-app: kube-dns }
> ```

> **!! ADDITIVE-POLICY CONFLICT with the main `networkPolicy` block. !!**
>
> Kubernetes **unions** all NetworkPolicies that select a pod. The main
> `networkPolicy` block (separate from this one) also selects the server /
> worker pods, and at its default `networkPolicy.egress.denyAll: false` it
> emits a `- {}` **allow-all egress** rule. That allow-all UNIONs with — and
> **nullifies** — any egress restriction here: the SurrealDB egress
> lock-down silently becomes a **no-op** in the common default combo.
>
> The chart **fails fast** on that exact footgun: requesting a true
> lock-down (`allowAllOtherEgress: false`) while `networkPolicy.enabled:
> true` *and* `networkPolicy.egress.denyAll: false` aborts `helm
> install/upgrade` with an explanatory error. To run a real SurrealDB egress
> lock-down you must pick ONE of:
>
> - `networkPolicy.enabled: false` (no competing egress policy), **or**
> - `networkPolicy.egress.denyAll: true` (the main policy stops emitting
>   `- {}` and instead allows only DNS + its own `egress.to` list — make sure
>   that list also covers the DB port and the same S3/SMTP/etc. peers), **or**
> - `surrealdb.networkPolicy.allowAllOtherEgress: true` (accept that this
>   policy is informational, not a restriction — the union is then
>   intentional and the DB-side firewall is the control).

**The egress policy is only half the control.** When the DB is external you
MUST also firewall it on its own side so other cluster workloads can't
reach `:8000`:

- **Managed in-cluster (Terraform `modules/surrealdb`):** add a matching
  ingress NetworkPolicy in the DB's own namespace selecting the SurrealDB
  pods and admitting only the nucel namespace
  (`namespaceSelector: { matchLabels: kubernetes.io/metadata.name: nucel }`).
- **Managed out-of-cluster (a VM / managed host):** lock the security group
  / host firewall on `:8000` to the cluster's pod/node CIDR only, and
  strongly prefer terminating the websocket behind TLS (`wss://`) — set
  `NUCEL_DB_URL` accordingly. Plaintext `ws://` over a routable network is
  not acceptable for production.

> NetworkPolicy enforcement can only be confirmed on a live cluster with a
> policy-enforcing CNI. `helm template` / `helm lint` validate that the
> right objects render for each `deploy` / `externalPeers` combination, but
> the actual deny behaviour must be smoke-tested in-cluster
> (`kubectl run` a throwaway pod and confirm it can't reach `:8000`).

## Non-root + restricted securityContext — audit #22

Every nucel workload pod carries a `securityContext` driven by two values
blocks — `podSecurityContext` (pod-level) and `containerSecurityContext`
(container-level) — wired through the `nucel.podSecurityContext` /
`nucel.containerSecurityContext` helpers. Coverage:

A ✅ below means the on-by-default hardened profile is applied
(`allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`,
`seccompProfile: RuntimeDefault`). It is **not** a claim of full
PSS-`restricted` compliance for the nucel pods: they run the **root** server
image, so `runAsNonRoot` / `readOnlyRootFilesystem` stay off and the pods
still run a root process (drop-ALL caps limits the blast radius). Full
`restricted` for those pods requires the non-root image rebuild tracked
below. The SurrealDB pod is the exception — it genuinely runs non-root.

| Workload | Pod SC | Container SC |
|----------|--------|--------------|
| `nucel-server` Deployment | ✅ partial¹ | ✅ partial¹ |
| `nucel-worker` Deployment | ✅ partial¹ | ✅ partial¹ |
| `nucel-worker-<pool>` Deployments | ✅ partial¹ | ✅ partial¹ |
| migration Job (`*-migrate`) | ✅ partial¹ | ✅ partial¹ |
| seed Job (`nucel-seed`) | ✅ partial¹ | ✅ partial¹ |
| SurrealDB StatefulSet | ✅ (uid/gid 1000, non-root) | ✅ |

> ¹ **partial** = drop-ALL caps + no-priv-escalation + RuntimeDefault seccomp
> are on, but `runAsNonRoot` / `readOnlyRootFilesystem` are off (root image),
> so this is not yet full PSS-`restricted`. Rebuild a non-root image to close
> the gap (below).

**What is on by default** (safe for the current root server image,
satisfies most of Pod Security "restricted"):

- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`

**What is intentionally OFF by default** — and why:

The published `ghcr.io/nucel-dev/nucel-server` image runs as **root (uid 0)**
(`docker/Dockerfile.server` is `debian:bookworm-slim` with no `USER`) and
the server writes to its PVC mounts (`/data/*`) plus a Vite manifest dir.
Setting `runAsNonRoot: true` on that image makes the kubelet refuse to start
the pod (`container has runAsNonRoot and image will run as root`), and
`readOnlyRootFilesystem: true` breaks the writes. So both are shipped
commented-out in `values.yaml`. **Do not flip them on the stock image.**

**Follow-up — rebuild a non-root image.** Add `USER 65532` to
`docker/Dockerfile.server` (and ensure `/data` + any writable dirs are
`fsGroup`-writable), then in your overlay switch the full restricted profile
on without forking the chart:

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532            # so the non-root uid can write the PVCs
  seccompProfile:
    type: RuntimeDefault
containerSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
  # readOnlyRootFilesystem: true   # only with writable emptyDirs over /tmp etc.
```

The SurrealDB StatefulSet already runs non-root (the `surrealdb/surrealdb`
image tolerates uid/gid 1000) — its pod `securityContext` sets
`runAsNonRoot: true` today and the container profile is added via
`surrealdb.containerSecurityContext`.

The seed Job's `mountRepos: true` path needs a root `fix-data-perms`
initContainer to `chown` the repos PVC; that init keeps `runAsUser: 0` but
otherwise carries the restricted profile (drops ALL caps except
`CHOWN`/`FOWNER`/`DAC_OVERRIDE`, no privilege escalation, RuntimeDefault
seccomp), and the Job's pod `securityContext` merges its required
`fsGroup: 0` on top of the shared profile rather than discarding it.
