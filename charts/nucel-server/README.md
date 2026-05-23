# nucel-server

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/nucel-server)](https://artifacthub.io/packages/helm/nucel-server/nucel-server)

Self-hosted git platform with built-in CI/CD, container registry, npm registry,
and AI agent orchestration. This chart deploys the `nucel-server` HTTP+SSH
service plus its supporting resources (Secret, ConfigMap, PVCs, optional
Ingress, optional SurrealDB, optional Karpenter NodePool, schema-migration
Job, opt-in HPA / PDB / ServiceMonitor / ExternalSecret).

- **Chart version:** `0.1.15`
- **App version (image tag default):** `0.5.9`
- **Default image:** `ghcr.io/nucel-dev/nucel-server:0.5.9`
- **Source:** <https://github.com/nucel-dev/nucel>
- **License:** MIT

> **Production deployments on the A-SAFE / Nucel managed cluster** pull from
> the private ECR mirror at
> `588738611061.dkr.ecr.eu-south-2.amazonaws.com/nucel-server:0.5.9`. Override
> `image.repository` in your values overlay to point at the mirror.

---

## Table of contents

1. [What this chart does](#what-this-chart-does)
2. [Architecture at a glance](#architecture-at-a-glance)
3. [Prerequisites](#prerequisites)
4. [Quickstart](#quickstart)
5. [Required secrets](#required-secrets)
6. [Configuration reference](#configuration-reference)
7. [Ingress / DNS](#ingress--dns)
8. [SurrealDB topology](#surrealdb-topology)
9. [Agent workflow (AW) runner dispatch](#agent-workflow-aw-runner-dispatch)
10. [Upgrading](#upgrading)
11. [Migration notes — 0.1.14 → 0.1.15](#migration-notes--0114--0115)
12. [Operations](#operations)
13. [Uninstalling](#uninstalling)
14. [Related docs](#related-docs)

---

## What this chart does

Renders the following resources by default:

| Resource | Purpose | Toggle |
|---|---|---|
| `Namespace` (×2) | `nucel` (app) and `nucel-ci` (runner Jobs + per-run Secrets) | `namespace.create`, `ciNamespace` |
| `Deployment nucel-server` | HTTP API (port `17321`) + SSH server (port `2222`) | always |
| `Service nucel-server` | ClusterIP exposing `http` + `ssh` | always |
| `ConfigMap` | non-secret env (`NUCEL_HOST`, `NUCEL_DB_URL`, repo paths, logging, AW knobs) | always |
| `Secret` (chart-managed) | `NUCEL_DB_PASS`, OIDC key, SSH host key, metrics token, OpenRouter key, Anthropic key, git-bot creds, S3 creds | `secrets.create` |
| `Secret nucel-ci-runner-secret` | runner token + API URL for `nucel-ci-operator` | `ciOperator.enabled` |
| `Secret nucel-aw-anthropic` | `ANTHROPIC_API_KEY` mounted into AW runner Pods | `secrets.anthropicApiKey` set |
| `PersistentVolumeClaim` (×4) | `nucel-repos`, `nucel-ci-data`, `nucel-registry`, `nucel-npm` (RWO) | always |
| `ServiceAccount` | IRSA-ready (annotate with `eks.amazonaws.com/role-arn`) | `serviceAccount.create` |
| `ClusterRole` + `ClusterRoleBinding` | permissions for the in-process job runner to create AW K8s Jobs | always |
| `Ingress` | controller-agnostic (ALB / nginx) — see `ingress.annotations` | `ingress.enabled` |
| `Job` (`pre-install`/`pre-upgrade`) | one-shot SurrealDB schema apply (`NUCEL_MIGRATE_ONLY=1`) | `migrations.enabled` |
| `Job` (`post-install`/`post-upgrade`) | optional fake-data seed (`nucel-seed`) | `seed.enabled` |
| `StatefulSet surrealdb` (+ Service) | in-chart SurrealDB (file or TiKV-backed) | `surrealdb.deploy` |
| `Karpenter NodePool` | durable `arm64-general` pool (EKS Auto Mode safe) | `nodePool.create` |
| `HorizontalPodAutoscaler` | CPU/memory-driven server scaling | `autoscaling.enabled` |
| `PodDisruptionBudget` | `minAvailable: 1` during drains / upgrades | `podDisruptionBudget.enabled` |
| `ServiceMonitor` | Prometheus Operator scrape config for `/metrics` | `prometheus.serviceMonitor.enabled` |
| `PrometheusRule` | queue-depth / DLQ / latency / fatal-rate alerts | `prometheus.alerts.enabled` |
| `ExternalSecret` | pulls Secret payload from AWS Secrets Manager / Vault | `externalSecrets.enabled` |
| `Deployment nucel-worker` (× N pools) | standalone job-runner pools per kind | `worker.enabled` |

## Architecture at a glance

```
                   ┌──────────────────────────┐
                   │   Ingress (ALB / nginx)  │
                   └──────────┬───────────────┘
                              │ HTTPS 443
                              ▼
                  ┌──────────────────────────┐
                  │  Service nucel-server    │  ClusterIP
                  │  http:17321  ssh:2222    │
                  └──────────┬───────────────┘
                             │
       ┌─────────────────────┴─────────────────────┐
       │                                           │
       ▼                                           ▼
┌──────────────┐  in-cluster DNS         ┌──────────────────┐
│ Deployment   │ ─────────────────────▶  │ SurrealDB v3.0.5 │
│ nucel-server │   ws://surrealdb:8000   │  (TiKV backend   │
│ (Axum + SSH) │                         │   in prod;       │
└──────┬───────┘                         │   file in dev)   │
       │                                 └──────────────────┘
       │ creates K8s Jobs
       ▼
┌──────────────────────┐
│ Namespace nucel-ci   │
│  ├─ aw-runner-* Job  │  (one per AW run, mounts ANTHROPIC_API_KEY)
│  └─ ci-pipeline-* Job│  (managed by nucel-ci-operator)
└──────────────────────┘
```

## Prerequisites

| Requirement | Why |
|---|---|
| Kubernetes ≥ 1.27 | uses `policy/v1` PDB, `autoscaling/v2`, `networking.k8s.io/v1` Ingress |
| Helm ≥ 3.12 | `required` template function, `lookup`, schema validation |
| A **SurrealDB v3.0.5** endpoint reachable from the cluster | the chart can deploy it (`surrealdb.deploy: true`) or you can point it at one managed externally (Terraform `modules/surrealdb`) |
| (EKS) Karpenter + EKS Auto Mode | for the bundled `arm64-general` NodePool |
| (EKS, recommended) `gp3` StorageClass with `WaitForFirstConsumer` | better IOPS/cost than `gp2`; correct multi-AZ scheduling |
| (Optional) Prometheus Operator (kube-prometheus-stack) | for `ServiceMonitor` + `PrometheusRule` resources |
| (Optional) External Secrets Operator | for the `ExternalSecret` resource |
| (Optional) AWS Load Balancer Controller / ingress-nginx | for the `Ingress` resource |
| (Optional) cert-manager | when terminating TLS in-cluster (skip on EKS+ACM) |

> **SurrealDB note** — Production clusters run `surrealdb/surrealdb:v3.0.5` against
> a **TiKV PD endpoint**, not the chart's `v2.6` default. Set
> `surrealdb.tikvEndpoint: "pd-pd.tikv-system.svc.cluster.local:2379"` and pin
> `surrealdb.image: surrealdb/surrealdb:v3.0.5` (already the chart default).

## Quickstart

### Local dev (kind, single replica, no TLS)

```bash
helm install nucel ./charts/nucel-server \
  --create-namespace --namespace nucel \
  --set secrets.requireProductionValues=false \
  --set prometheus.requireAuth=false \
  --set surrealdb.deploy=true \
  --set cookies.secure="0"
```

### Production (EKS, ALB, ESO, gp3)

```bash
helm upgrade --install nucel ./charts/nucel-server \
  --namespace nucel --create-namespace \
  -f ./charts/nucel-server/values.yaml \
  -f ./charts/nucel-server/values-production.yaml \
  --set image.repository=588738611061.dkr.ecr.eu-south-2.amazonaws.com/nucel-server \
  --set image.tag=0.5.9 \
  --set domain=app.nucel.dev \
  --set ingress.enabled=true \
  --set ingress.className=alb \
  --set storage.storageClassName=gp3 \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::588738611061:role/nucel-server-irsa
```

### Render without installing (CI / drift)

```bash
helm template nucel ./charts/nucel-server \
  -f ./charts/nucel-server/values-production.yaml \
  --set secrets.oidcPrivateKey="$(openssl genpkey -algorithm ED25519)" \
  --set secrets.metricsToken="$(openssl rand -base64 32)" \
  > /tmp/nucel.yaml
```

## Required secrets

The chart's secret model has three layers:

1. **Chart-managed `Secret`** (`secrets.create: true`, the default) — values are
   read from `.Values.secrets.*`.
2. **ExternalSecret** (`externalSecrets.enabled: true`, `secrets.create: false`)
   — payload is pulled from a remote backend (AWS Secrets Manager / Vault / …)
   and materialised into the same Secret name.
3. **Externally managed Secret** (`secrets.create: false`,
   `externalSecrets.enabled: false`) — you create the Secret yourself with
   the right name (`<release>-nucel-server-secrets`); the chart only references it.

### Required at install time

These are enforced by Helm's `required` template function — `helm install/upgrade`
**refuses to render** when empty:

| Key | Env var | Gated by | Generate with |
|---|---|---|---|
| `secrets.oidcPrivateKey` | `NUCEL_OIDC_PRIVATE_KEY` | `secrets.create=true` AND `secrets.requireProductionValues=true` (default) | `openssl genpkey -algorithm ED25519` |
| `secrets.metricsToken` | `NUCEL_METRICS_TOKEN` | `prometheus.requireAuth=true` (default) | `openssl rand -base64 32` |
| `externalSecrets.secretStoreRef.name` | — | `externalSecrets.enabled=true` | name of your `ClusterSecretStore` |
| `externalSecrets.remoteRef.key` | — | `externalSecrets.enabled=true` | remote key whose JSON payload holds every `NUCEL_*` value |

### Strongly recommended

| Key | Env var | Effect when empty |
|---|---|---|
| `secrets.sshHostKey` | `NUCEL_SSH_HOST_KEY` | SSH host key rotates every pod restart → `known_hosts` MITM warning on every reconnect |
| `secrets.dbPass` | `NUCEL_DB_PASS` | SurrealDB starts with the chart-default empty password — never expose externally |
| `secrets.hookSecret` | `NUCEL_HOOK_SECRET` | webhook signatures unverifiable; downstream consumers will reject deliveries |
| `secrets.ciRunnerToken` | `NUCEL_CI_RUNNER_TOKEN` (mirrored into `nucel-ci-runner-secret`) | `nucel-ci-operator` cannot authenticate runners back to the server |
| `secrets.openrouterKey` | `NUCEL_OPENROUTER_KEY` | AW threat scanner runs in offline mode (always `pass`) — no prompt-injection / leaked-secrets gating |
| `secrets.anthropicApiKey` | `ANTHROPIC_API_KEY` (mirrored into `nucel-aw-anthropic` Secret in `ciNamespace`) | AW runner pods boot without an Anthropic key → claude-code SDK calls fail at runtime |
| `secrets.gitBotUser` / `secrets.gitBotPassword` | `NUCEL_GIT_USER`, `NUCEL_GIT_PASSWORD` | `mint_scoped_pat` returns `None` → AW K8s dispatch is skipped (stub mode) |

### Generating all required values at once

```bash
openssl genpkey -algorithm ED25519 -out /tmp/nucel-oidc.key
ssh-keygen -t ed25519 -N "" -f /tmp/nucel-ssh-host -C "nucel-ssh-host"
openssl rand -base64 32 > /tmp/nucel-metrics.token

helm upgrade --install nucel ./charts/nucel-server \
  --set-file secrets.oidcPrivateKey=/tmp/nucel-oidc.key \
  --set-file secrets.sshHostKey=/tmp/nucel-ssh-host \
  --set-file secrets.metricsToken=/tmp/nucel-metrics.token \
  --set secrets.dbPass="$(openssl rand -hex 32)" \
  --set secrets.hookSecret="$(openssl rand -hex 32)" \
  --set secrets.ciRunnerToken="$(openssl rand -hex 32)" \
  --set secrets.anthropicApiKey="$ANTHROPIC_API_KEY" \
  --set secrets.openrouterKey="$OPENROUTER_KEY"
```

### Registry credentials (image pull)

For private registries (e.g. the A-SAFE ECR mirror), create an
`imagePullSecret` out-of-band and reference it through your ServiceAccount —
the chart does not render `imagePullSecrets` itself.

```bash
aws ecr get-login-password --region eu-south-2 \
  | kubectl create secret docker-registry ecr-creds \
      --docker-server=588738611061.dkr.ecr.eu-south-2.amazonaws.com \
      --docker-username=AWS --docker-password-stdin \
      --namespace nucel

kubectl patch serviceaccount nucel-nucel-server \
  -n nucel \
  -p '{"imagePullSecrets":[{"name":"ecr-creds"}]}'
```

On EKS, prefer **IRSA + ECR pull-through** instead of long-lived docker creds.

## Configuration reference

Below is the canonical configuration table. Every key in `values.yaml` has a
matching inline comment — this table is a quick index, not a replacement for
reading the values file.

### Image

| Key | Default | Notes |
|---|---|---|
| `image.repository` | `ghcr.io/nucel-dev/nucel-server` | Override for the ECR mirror in prod |
| `image.tag` | `""` | Empty → falls back to `Chart.AppVersion` (`0.5.9`). Never pin to `latest` |
| `image.pullPolicy` | `IfNotPresent` | |

### Server / worker

| Key | Default | Notes |
|---|---|---|
| `server.replicas` | `1` | Initial replicas; HPA owns the scale subresource when enabled |
| `server.port` | `17321` | HTTP listener |
| `server.sshPort` | `2222` | SSH listener |
| `server.resources` | 200m / 256Mi → 1 CPU / 1Gi | |
| `worker.enabled` | `false` | Standalone job-runner Deployment (the in-process runner inside `nucel-server` covers low-volume installs) |
| `worker.pools` | `[]` | List of per-kind worker Deployments; supports `shardIndex` / `shardCount` for hash partitioning |

### Migrations (Helm hook Job)

| Key | Default | Notes |
|---|---|---|
| `migrations.enabled` | `true` | When on, the server pods get `NUCEL_SKIP_SCHEMA=1` and a pre-upgrade Job applies the schema exactly once |
| `migrations.backoffLimit` | `2` | |
| `migrations.activeDeadlineSeconds` | `600` | Hard ceiling on migration runtime |

### Domain & OIDC

| Key | Default | Notes |
|---|---|---|
| `domain` | `nucel.dev` | Used for ingress host + cookie domain |
| `oidc.issuer` | `https://nucel.dev` | Must match the public URL clients see |
| `cookies.secure` | `"1"` | Set to `"0"` only for local plaintext dev — browsers drop Secure cookies on HTTP |

### SurrealDB

| Key | Default | Notes |
|---|---|---|
| `surrealdb.deploy` | `false` | `false` in production (Terraform `modules/surrealdb` owns it); `true` only for kind / dev |
| `surrealdb.image` | `surrealdb/surrealdb:v3.0.5` | Pinned — must match the schema and TiKV protocol |
| `surrealdb.tikvEndpoint` | `""` | Non-empty enables TiKV mode and skips the chart-managed PVC |
| `surrealdb.storage` | `20Gi` | Used only when `tikvEndpoint` is empty |

### Storage

| Key | Default | Notes |
|---|---|---|
| `storage.repos` | `50Gi` | Git repos (PVC `nucel-repos`) |
| `storage.ciData` | `50Gi` | CI logs + artifacts (PVC `nucel-ci-data`) |
| `storage.registry` | `20Gi` | OCI/Docker registry blobs |
| `storage.npm` | `10Gi` | npm registry blobs |
| `storage.storageClassName` | `""` | **EKS: set to `gp3`** with `WaitForFirstConsumer` |
| `repoStorage.kind` | `local` | `local` keeps repos on the PVC; `s3` enables a cold tier on object storage |
| `repoStorage.s3.*` | — | bucket / prefix / region / endpoint; prefer IRSA over `accessKeyId`/`secretAccessKey` |

### Ingress

| Key | Default | Notes |
|---|---|---|
| `ingress.enabled` | `false` | |
| `ingress.className` | `""` | `alb` on EKS+ALB, `nginx` on ingress-nginx |
| `ingress.annotations` | `{}` | Drives controller-specific behaviour — see `values.yaml` for ALB + nginx examples |
| `ingress.tls` | `true` | `true` → single-host SNI block; `false` → no TLS (ACM terminates upstream); raw list passed through verbatim for multi-host |
| `ingress.tlsSecretName` | `""` | Override the default `<release>-nucel-server-tls` |

### Service account

| Key | Default | Notes |
|---|---|---|
| `serviceAccount.create` | `true` | |
| `serviceAccount.name` | `""` | Bind to an externally-managed SA |
| `serviceAccount.annotations` | `{}` | **IRSA wiring**: stamp `eks.amazonaws.com/role-arn` here |

### Secrets — see [Required secrets](#required-secrets) above

### External Secrets Operator

| Key | Default | Notes |
|---|---|---|
| `externalSecrets.enabled` | `false` | Renders an `ExternalSecret` CRD pulling the chart's Secret from a remote backend |
| `externalSecrets.refreshInterval` | `1h` | ESO polling cadence |
| `externalSecrets.secretStoreRef.name` | `""` | name of your `ClusterSecretStore` / `SecretStore` |
| `externalSecrets.secretStoreRef.kind` | `ClusterSecretStore` | or `SecretStore` |
| `externalSecrets.remoteRef.key` | `""` | remote key whose JSON payload contains every `NUCEL_*` value |

### Agent workflows (AW)

| Key | Default | Notes |
|---|---|---|
| `agentWorkflows.k8s.url` | `""` | Set to `https://kubernetes.default.svc` to enable AW K8s dispatch. Empty disables runner pod creation |
| `agentWorkflows.k8s.namespace` | `nucel-ci` | Where AW runner Jobs + per-run Secrets are created |
| `agentWorkflows.k8s.apiUrl` | `""` | Callback URL the runner uses to reach `nucel-server`; defaults to in-cluster DNS |
| `agentWorkflows.k8s.runnerImage` | `""` | OCI image for `nucel-aw-runner`. **Required when `k8s.url` is set** |
| `agentWorkflows.k8s.anthropicSecret` | `nucel-aw-anthropic` | Secret name in `k8s.namespace` holding `ANTHROPIC_API_KEY` |
| `agentWorkflows.tickPeriodSeconds` | `300` | `aw_tick` scheduler cadence |
| `agentWorkflows.manualTriggerPerMin` | `5` | Per-workflow manual-trigger rate limit |
| `agentWorkflows.orgManualTriggerPerMin` | `20` | Org-wide manual-trigger rate limit |
| `agentWorkflows.dailyOrgUsdCap` | `0` | Org-wide daily spend ceiling (USD). `0` = disabled |
| `agentWorkflows.needsReviewTtlHours` | `168` | Auto-reject `needs_review` runs older than this. `0` = disabled |
| `agentWorkflows.runStuckTimeoutMin` | `60` | Auto-fail runners stuck running / scanning / applying. `0` = disabled |
| `agentWorkflows.autoDisableAfterNFails` | `0` | Circuit breaker. `0` = disabled |
| `agentWorkflows.orgMaxConcurrent` | `0` | Org-wide in-flight cap. `0` = disabled |

### Karpenter NodePool (EKS Auto Mode)

| Key | Default | Notes |
|---|---|---|
| `nodePool.create` | `true` | `arm64-general` pool — survives EKS Auto Mode reconciliation |
| `nodePool.name` | `arm64-general` | |
| `nodePool.limits.cpu` | `"100"` | |
| `nodePool.limits.memory` | `"200Gi"` | |

### CI operator

| Key | Default | Notes |
|---|---|---|
| `ciNamespace` | `nucel-ci` | Where pipeline + AW runner Jobs land |
| `ciOperator.enabled` | `true` | When on, the chart also renders the `nucel-ci-runner-secret` Secret |
| `ciOperator.runnerToken` | `""` | Falls back to `secrets.ciRunnerToken` |

### Observability

| Key | Default | Notes |
|---|---|---|
| `prometheus.requireAuth` | `true` | Fails fast if `secrets.metricsToken` is empty |
| `prometheus.alerts.enabled` | `false` | Ships `PrometheusRule` CRDs (queue depth / DLQ / latency / fatal-rate) |
| `prometheus.alerts.pendingDepthThreshold` | `1000` | |
| `prometheus.alerts.claimLatencyP99` | `0.5` | seconds |
| `prometheus.alerts.fatalRate` | `1` | per second |
| `prometheus.serviceMonitor.enabled` | `false` | Ships a `ServiceMonitor` for Prometheus Operator |
| `prometheus.serviceMonitor.interval` | `30s` | |
| `prometheus.serviceMonitor.scrapeTimeout` | `10s` | |
| `prometheus.serviceMonitor.labels` | `{}` | Typically `release: kube-prometheus-stack` |

### Reliability

| Key | Default | Notes |
|---|---|---|
| `autoscaling.enabled` | `false` | HPA against the main `nucel-server` Deployment |
| `autoscaling.minReplicas` / `maxReplicas` | `2` / `10` | |
| `autoscaling.targetCPUUtilizationPercentage` | `70` | |
| `autoscaling.targetMemoryUtilizationPercentage` | `80` | |
| `podDisruptionBudget.enabled` | `true` | `minAvailable: 1` — pair with `server.replicas >= 2` |
| `podDisruptionBudget.minAvailable` | `1` | |
| `podDisruptionBudget.maxUnavailable` | `null` | mutually exclusive with `minAvailable` |

### Logging

| Key | Default | Notes |
|---|---|---|
| `logging.level` | `info` | |
| `logging.rustLog` | `info,nucel_server=info,tower_http=warn` | `RUST_LOG` env var |

### Seed (fake-data generator)

See `values.yaml` → `seed:` block. Off by default. Run with
`--set seed.enabled=true --set seed.scale=medium`.

## Ingress / DNS

The chart is controller-agnostic. Two reference shapes:

### EKS + AWS Load Balancer Controller (ACM-terminated)

```yaml
domain: app.nucel.dev
ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:eu-south-2:588738611061:certificate/<uuid>
    alb.ingress.kubernetes.io/healthcheck-path: /health
  tls: false   # ALB terminates via ACM
```

DNS is handled by `external-dns` (set up in `nucel-infra/modules/external-dns/`).

### ingress-nginx + cert-manager

```yaml
domain: app.nucel.dev
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 100m
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls: true
```

### SSH

The chart's `Service` exposes the SSH listener on `:2222` as a ClusterIP. To
expose it externally, layer a `Service type=LoadBalancer` or
`Service type=NodePort` on top — neither is rendered by this chart.

## SurrealDB topology

This chart supports three topologies for the database:

1. **In-chart, file-backed** (`surrealdb.deploy: true`, `tikvEndpoint: ""`) —
   single-replica `StatefulSet` with a chart-managed PVC. Suitable for kind /
   local dev only.
2. **In-chart, TiKV-backed** (`surrealdb.deploy: true`, `tikvEndpoint` set) —
   stateless `StatefulSet`; data lives in the TiKV cluster.
3. **External** (`surrealdb.deploy: false`) — chart does not render the
   StatefulSet; `NUCEL_DB_URL` still points at
   `ws://surrealdb.<namespace>.svc.cluster.local:8000`, so the externally
   managed StatefulSet must keep the `surrealdb` Service name.

**Production (neoconto / A-SAFE):** topology #3 — `modules/surrealdb` in
`nucel-infra` deploys `surrealdb/surrealdb:v3.0.5` against
`pd-pd.tikv-system.svc.cluster.local:2379`. The chart's default
`surrealdb.image` (`v3.0.5`) matches this, but the `v2.6` schema baseline
some older overlays still reference is **not** what's deployed — verify your
overlay before applying.

## Agent workflow (AW) runner dispatch

When `agentWorkflows.k8s.url` is set, the server's `aw_dispatch` handler
creates one `Job` per AW run in `agentWorkflows.k8s.namespace` (default
`nucel-ci`). Each Job:

- runs `agentWorkflows.k8s.runnerImage` (the `nucel-aw-runner` binary).
- mounts `ANTHROPIC_API_KEY` from the `agentWorkflows.k8s.anthropicSecret`
  Secret (default `nucel-aw-anthropic`). The chart creates this Secret in
  `ciNamespace` automatically when `secrets.anthropicApiKey` is set.
- receives a fresh per-run scoped PAT minted by the server (requires
  `secrets.gitBotUser` + `secrets.gitBotPassword`).
- calls back to the server at `agentWorkflows.k8s.apiUrl` (or the in-cluster
  default).

> **Wave 0.1.15 change** — AW runs now dispatch as plain Kubernetes Jobs
> directly. The earlier `PipelineJobRun` CRD path is gone. The CRD itself
> still exists (managed by `nucel-ci-operator` for non-AW pipelines) but is
> no longer on the AW dispatch path.

## Upgrading

The chart's image tag defaults to `Chart.AppVersion`, so a `helm upgrade`
that bumps `Chart.yaml` is sufficient to roll the image. Before upgrading:

```bash
helm diff upgrade nucel ./charts/nucel-server \
  -f values-production.yaml \
  --reuse-values
```

A pre-upgrade Hook Job (`migrations.enabled: true`) runs `NUCEL_MIGRATE_ONLY=1`
against SurrealDB and exits before any server pod restarts. Watch with:

```bash
kubectl -n nucel logs job/nucel-nucel-server-migrate -f
```

If the Job fails, the upgrade is aborted; the previous server pods keep
running.

## Migration notes — 0.1.14 → 0.1.15

> 0.1.14 was never tagged; 0.1.9 → 0.1.15 collapses several PRs.

| Change | Impact |
|---|---|
| **AW K8s Job dispatch** replaces the `PipelineJobRun` CRD path for AW runs (`84af9a5`) | New env vars on the server pod: `NUCEL_AW_K8S_URL`, `NUCEL_AW_K8S_NAMESPACE`, `NUCEL_AW_RUNNER_IMAGE`, `NUCEL_AW_ANTHROPIC_SECRET`. `ClusterRole` now grants `create`/`get`/`list` on `batch/jobs` + `core/secrets` in `ciNamespace`. **Action:** set `agentWorkflows.k8s.url` + `agentWorkflows.k8s.runnerImage` if you want AW dispatch. |
| **`ANTHROPIC_API_KEY` wired through the chart** (`9df8247`) | New value `secrets.anthropicApiKey`. When set, mirrors into a second Secret `nucel-aw-anthropic` in `ciNamespace`. **Action:** add the key to your values overlay or ExternalSecret payload. |
| **Nil-guards across templates** (`a6b959c`, `85c15aa`, `d1add09`, `cea5cab`, `62e3417`, `d8558b0`) | Templates no longer error when sub-keys (`cookies`, `repoStorage`, `migrations`, `agentWorkflows`, `serviceAccount`, `nodePool`, `worker`) are unset. **Action:** none — purely defensive. |
| **AppVersion bump** `0.5.3` → `0.5.9` | Includes the AW runner SDK update + agent SDK integration. **Action:** mirror the new image into your private registry before applying. |

There are no backward-incompatible value-renames in this range.

## Operations

### Common kubectl recipes

```bash
# Tail server logs
kubectl -n nucel logs -l app.kubernetes.io/name=nucel-server -f --tail=200

# Tail the migration Job
kubectl -n nucel logs job/nucel-nucel-server-migrate -f

# Run the schema apply manually (out-of-band)
kubectl -n nucel exec deploy/nucel-server -- /usr/local/bin/nucel-server --migrate-only

# Force a rolling restart (e.g. after secret rotation)
kubectl -n nucel rollout restart deploy/nucel-server

# Inspect the chart-managed Secret
kubectl -n nucel get secret nucel-nucel-server-secrets -o json | jq '.data | keys'

# Patch in a fresh OIDC key without rebuilding the chart
openssl genpkey -algorithm ED25519 -out /tmp/k
kubectl -n nucel patch secret nucel-nucel-server-secrets --type=merge \
  -p="$(jq -n --rawfile k /tmp/k '{stringData: {NUCEL_OIDC_PRIVATE_KEY: $k}}')"
kubectl -n nucel rollout restart deploy/nucel-server
```

### Secret rotation procedure

| Secret | Procedure |
|---|---|
| `ANTHROPIC_API_KEY` | Update AWS Secrets Manager → ESO refreshes within `externalSecrets.refreshInterval` (default 1h). For immediate effect: `kubectl -n nucel annotate externalsecret nucel-server force-sync=$(date +%s) --overwrite`. Then restart server: `kubectl -n nucel rollout restart deploy/nucel-server`. |
| `NUCEL_OIDC_PRIVATE_KEY` | Same procedure. **Note:** rotating this invalidates every in-flight OIDC token; expect a one-time mass re-auth. |
| `NUCEL_SSH_HOST_KEY` | Generate a new key, update Secret, restart. **Warning:** every client with `known_hosts` pinning sees the MITM warning until they re-accept. Prefer rotating only on key compromise. |
| Registry pull creds (ECR) | ECR tokens last 12h. Use `aws ecr get-login-password` in a CronJob or switch to IRSA + ECR pull-through (no rotation needed). |

### Storage migration (RWO → RWX)

The chart ships `ReadWriteOnce` PVCs. When you need worker pods on a
different node than the writer (or a multi-replica server reading the same
`/data/repos`), switch `storage.storageClassName` to a RWX class (EFS CSI,
NFS, Longhorn-RWX). The chart does not perform the PVC migration itself —
plan a maintenance window:

1. Stop the Deployment (`kubectl scale deploy/nucel-server --replicas=0`).
2. Snapshot the old PVCs.
3. Create new PVCs against the RWX class with `kubectl edit pvc ...` or by
   re-rendering the chart with the new `storageClassName`.
4. Copy data over (`rsync` from a temporary pod).
5. Scale back up.

## Uninstalling

```bash
helm uninstall nucel -n nucel
```

`helm uninstall` does NOT delete:

- **PVCs** (`nucel-repos`, `nucel-ci-data`, `nucel-registry`, `nucel-npm`).
  Delete by hand if you want the storage reclaimed.
- The `nucel-ci` namespace — it's a separate namespace and may contain
  in-flight Jobs.
- ExternalSecrets-managed Secrets (`secrets.create=false`).
- The Karpenter NodePool (`nodePool.create=true` was a Helm-owned resource;
  it IS removed by uninstall, but the nodes it provisioned are drained
  asynchronously).

## Related docs

- [`PRODUCTION_HARDENING.md`](./PRODUCTION_HARDENING.md) — every "Fix X"
  referenced in the values comments (C8 OIDC, C9 SSH host key, H1 HPA, H2 PDB,
  H4 ServiceMonitor, H6 ExternalSecrets, H7 gp3, H9 metrics token, M1 image
  tag, M5 migration hook).
- [`values-production.yaml`](./values-production.yaml) — the production
  overlay shape.
- [`CHANGELOG.md`](./CHANGELOG.md) — chart version history.
- `nucel-infra/` (sibling repo) — Terraform / OpenTofu for the EKS + Hetzner
  clusters that consume this chart.
