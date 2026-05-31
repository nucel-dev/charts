# Changelog — nucel-server chart

All notable changes to the `nucel-server` Helm chart are recorded here.

The chart follows [Semantic Versioning](https://semver.org/) for `version:`
(chart shape) and tracks `appVersion:` to the underlying `nucel-server` image
release.

> Generated from `git log -- charts/nucel-server/`. Each entry lists the
> short SHA, date, and a summary of the user-visible effect.

## [0.1.37] — 2026-05-30 (appVersion 0.5.27)

### Added

- **Production SLO + health PrometheusRule** (`templates/prometheusrule.yaml`,
  gated `metrics.alerts.enabled`, default off). The platform-wide alerting
  layer for a many-user install — additive to and separate from the existing
  bg_job-only `prometheus-rules.yaml` (kept under `prometheus.alerts.*` for
  back-compat). Rules: `NucelHttp5xxRateHigh`,
  `NucelAvailabilityBudgetFastBurn` (14.4× error-budget burn),
  `NucelWebP99LatencySloBreach`, `NucelBgJobQueueDepthHigh`,
  `NucelBgJobDispatchStalled`, `NucelBgJobClaimLatencyP99High`,
  `NucelBgJobDlqNonEmpty`, `NucelDbQueryP99High`, `NucelSseConnectionLeak`
  (the #281 regression guard), `NucelRegistryBlobP99High`,
  `NucelPodCrashLooping`, `NucelPodOOMKilled`, `NucelDeploymentNotReady`,
  `NucelHpaAtMaxReplicas`, `NucelPvcNearFull`, plus opt-in
  `NucelTlsCertExpiringSoon` (cert-manager) and `NucelNoSuccessfulBackup`
  (backup-pipeline coordinated). Every threshold is a
  `metrics.alerts.thresholds.*` value; SLO defaults track `load/PLAN_1M.md` §4.
  `severity: critical` → page, `severity: warning` → ticket.
- **Grafana dashboard: SLO row + HTTP/DB/SSE/Registry panels.** The top-level
  "SLO" row (availability %, 5xx ratio, web/API p99, DB p99) and a new
  HTTP/DB/SSE/Registry row (HTTP RED, DB query quantiles by op, open SSE
  connections by stream, registry blob throughput + latency) replace the old
  "metrics not exported yet" placeholder text panel — those families
  (`nucel_http_*`, `nucel_db_query_*`, `nucel_sse_connections`,
  `nucel_registry_blob_*`) are now exported by the server.
- **`metrics.alerts.*` values block** — `enabled`, `labels`, per-alert
  `thresholds`, opt-in `certExpiry` / `backup`, and a documented
  `alertmanagerRouting` reference (severity → channel) for the
  kube-prometheus-stack Alertmanager config. No secrets/webhooks hardcoded —
  routing keys/webhooks are mounted from a Secret via `*_file`.
- **SLO runbook** (`docs/runbooks/slos.md`) — per-surface availability +
  latency SLOs, error-budget/burn-rate math, page-vs-ticket alert table, and
  the Alertmanager routing snippet.

## [0.1.36] — 2026-05-30 (appVersion 0.5.27)

### Added

- **Pod- + container-level SecurityContext** (`podSecurityContext` /
  `containerSecurityContext`) wired into the server, worker, and worker-pool
  Deployments via two new `_helpers.tpl` includes. Container default is the
  safe-on-root profile (`allowPrivilegeEscalation: false`,
  `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`); pod default
  sets `seccompProfile: RuntimeDefault`. `runAsNonRoot` and
  `readOnlyRootFilesystem` are deliberately **left off by default** — the
  published `nucel-server` image runs as root (debian:bookworm-slim, no `USER`)
  and writes to `/data/*` + the Vite manifest dir, so forcing them on the stock
  image would crash-loop the pod. Both blocks are full `toYaml` pass-throughs so
  operators who rebuild a nonroot image can flip the restricted profile on
  without forking the chart. Set either block to `{}` to emit nothing.
- **Startup probe on the server container** (`server.probes.startup`, on by
  default). Until it passes, the liveness probe is not evaluated, so a slow cold
  boot (SurrealDB connect + schema check + SSH host-key load) can no longer be
  misread as a crash-loop. Liveness / readiness timings are now fully
  parameterised under `server.probes.{liveness,readiness}` (previously
  hard-coded).
- **Optional NetworkPolicy** (`networkPolicy.enabled`, off by default) selecting
  all nucel pods by `app.kubernetes.io/name`. Ingress allows the HTTP (17321) +
  SSH (2222) ports (narrowable via `networkPolicy.ingress.from`); egress always
  permits DNS and defaults to allow-all (the server reaches SurrealDB/TiKV, S3,
  SMTP, the K8s API, webhooks and git remotes). Set
  `networkPolicy.egress.denyAll: true` + `egress.to` to lock egress down.

### Notes

- All additions are additive and `{{- with }}`/`default`-guarded — existing
  installs upgrade with no behavioural change unless they opt in. The stock
  root image is unaffected by the default securityContext.

## [0.1.35] — 2026-05-30 (appVersion 0.5.27)

### Fixed

- **Pod scheduling fields now actually render.** `affinity`,
  `topologySpreadConstraints`, `priorityClassName` (cluster-wide keys) plus the
  new `server.nodeSelector` / `server.tolerations` / `server.strategy` were
  defined in `values.yaml` but never emitted by `templates/deployment.yaml` —
  the pod spec went straight from `serviceAccountName` to `containers`, so
  server replicas had no AZ spread, no anti-affinity, and no rolling-update
  strategy. All are now wired into the server Deployment, each guarded with
  `{{- with ... }}` so an empty value is omitted, and `strategy` is set at the
  Deployment level.
- **Worker scheduling parity.** `worker-deployment.yaml` had the same gap; it
  now renders `worker.{nodeSelector,affinity,topologySpreadConstraints,tolerations,priorityClassName}`
  plus a Deployment-level `worker.strategy`.

### Added

- **Default multi-AZ spread out of the box.** `values.yaml` already shipped a
  soft pod anti-affinity by `kubernetes.io/hostname` plus a
  `topologySpreadConstraints` on `topology.kubernetes.io/zone`
  (`maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway`); these now reach the
  Deployment for production AZ spread without extra config. Fully overridable /
  emptyable. The worker gains its own worker-scoped soft anti-affinity + zone
  spread defaults.
- **Server + worker rolling-update strategy** (`server.strategy` /
  `worker.strategy`): `maxSurge: 1`, `maxUnavailable: 0` so the fleet stays at
  full capacity through rollouts.
- New `server.nodeSelector` / `server.tolerations` keys (previously only the
  `seed` block had these).

## [0.1.34] — 2026-05-30 (appVersion 0.5.27)

### Added

- Per-class storage strategy: new `storage.classes.<class>` block picks a
  `backend` (`s3` | `pvc` | `emptyDir`) per data class (`pages`, `registry`,
  `npm`, `artifacts`, `gitWorkspaces`, `workspaces`) with per-class `size` /
  `accessMode` / `storageClassName` and S3 config for the S3-capable classes.
- Bundled Grafana dashboard: optional `monitoring.grafanaDashboard` ships the
  `nucel-server-overview` dashboard as a sidecar-discovered ConfigMap
  (`grafana_dashboard` label, configurable). Additive — leaves hand-built
  dashboards untouched.
- `ServiceMonitor` for Prometheus Operator discovery of the server's
  `/metrics` endpoint, gated by `monitoring.serviceMonitor`.

### Changed

- HPA tuning for the larger-fleet target: `hpa.minReplicas` 2 → 3 (PDB
  `minAvailable: 1` + topology spread keeps 2 pods serving through a node/zone
  loss), `maxReplicas` 10 → 30, `targetCPUUtilizationPercentage` 70 → 60 for
  headroom on bursty handlers (argon2 / upload-pack / blob streaming). Legacy
  `autoscaling.*` kept in sync with the canonical `hpa.*` block.

### Fixed

- **#244:** pages assets now mount a real volume at `/data/pages` (previously
  written to the ephemeral container layer — wiped on pod cycle, invisible to
  sibling pods, ~50% 404 race under multiple replicas). `NUCEL_PAGES_PATH` set
  explicitly.
- `helm install/upgrade` guard (`nucel.storage.validate`) now fails fast when
  `server.replicas > 1` / HPA is paired with a `ReadWriteOnce` PVC or
  `emptyDir` on a shared class (the Multi-Attach error), and rejects
  `backend: s3` on filesystem-only classes (registry/npm/artifacts).

### Notes

- `values-production.yaml`: pages → S3 (IRSA); registry/npm/artifacts/
  gitWorkspaces → EFS `ReadWriteMany`.
- Legacy `storage.{repos,ciData,registry,npm,storageClassName}` and the
  `pagesStorage` / `repoStorage` blocks remain honored as fallbacks, so
  existing single-replica installs upgrade unchanged.

## [0.1.33] — 2026-05-30 (appVersion 0.5.27)

### Changed

- Bump `appVersion` to `0.5.27` (observability rollout: Prometheus metrics +
  Grafana dashboards on the server image).

## 0.1.23 — 2026-05-24 (appVersion 0.5.17)

**MVP demo v6 unblock — three independent fixes bundled into one chart bump.**

- **Bug 1 fix (`b601432`):** `fix(aw-apply): backfill open-pull-request branch
  from sibling commit-files` — an agent emitting both `commit-files` and
  `open-pull-request` could omit `branch` on the PR output. The validator
  rejected the artifact and the run lands at `blocked` with no PR row
  created (silent no-op from the user's POV). Apply now backfills the
  branch before validation runs.
- **Bug 2 fix (`660d92e`):** `fix(pages): swappable storage backend
  (NUCEL_PAGES_STORAGE=fs|s3)` — the previous deploy_pages handler wrote
  the live tree to a pod-local PVC. With 2+ replicas the other pod 404'd
  for ~50% of requests until a re-deploy happened to land on the missing
  pod. New `pagesStorage.*` values block + `NUCEL_PAGES_STORAGE` env var
  let operators put assets on S3 (every replica reads the same bytes).
  Defaults to `fs` for back-compat — startup logs a WARN explaining the
  multi-replica caveat.
- **Bug 3 fix (`d59bfcb`):** `fix(pages): accept branch/dir aliases on
  CREATE + PATCH bodies` — `POST /api/v1/repos/{owner}/{repo}/pages` with
  `{"branch": "main"}` was silently ignored (fell through to the
  `gh-pages` default). Both `source_branch` and `branch` now work, same
  for `source_dir`/`dir`.

**Action for operators:** for multi-replica deploys, set
`pagesStorage.kind: s3` and fill in `pagesStorage.s3.bucket` (or leave it
empty to reuse `repoStorage.s3.bucket`). Single-replica deploys can keep
the default `fs` and ignore the WARN line.


## 0.1.16 — 2026-05-24 (appVersion 0.5.9)

**Fix (B-15):** `fix(auth): require shared session signing key across replicas`

- New value `secrets.sessionKey`: cookie signing key shared across every
  `nucel-server` replica. Without it, each pod signs `nucel_session`
  cookies with its own ephemeral `tower_sessions::cookie::Key` and any
  request load-balanced to a sibling pod fails signature validation,
  logging the user out at random.
- The chart-managed Secret now exposes `NUCEL_SESSION_KEY`:
  - Explicit `secrets.sessionKey` wins.
  - Otherwise `lookup` carries the existing Secret value forward across
    upgrades (sticky after first install).
  - Otherwise required when `secrets.requireProductionValues=true`.
  - Otherwise a `randAlphaNum 64` value is generated on first install
    and pinned by the `lookup` branch on every subsequent upgrade.
- Server panics at startup when `NUCEL_SESSION_KEY` is unset AND
  `NUCEL_ALLOW_DEV_SECRETS=1` is NOT set -- mirrors the existing
  `NUCEL_HOOK_SECRET` / `NUCEL_CI_RUNNER_TOKEN` behaviour.
- Migration note for operators: existing installs picking up 0.1.16
  will have a new key generated automatically -- every active session
  is invalidated once (one-time logout). To avoid that, set
  `secrets.sessionKey` from a previously-captured value before the
  upgrade.

## 0.1.15 — 2026-05-23 (appVersion 0.5.9)

**Commit:** `84af9a5` — `fix(aw): dispatch AW runs as K8s Jobs directly, bypass PipelineJobRun CRD (#39)`

- Agent-workflow (AW) runs now dispatch as plain Kubernetes `Job` resources
  via `aw_k8s_dispatch` instead of going through the `PipelineJobRun` CRD.
- New env vars on the server pod (gated on `agentWorkflows.k8s.url`):
  `NUCEL_AW_K8S_URL`, `NUCEL_AW_K8S_NAMESPACE`, `NUCEL_AW_API_URL`,
  `NUCEL_AW_RUNNER_IMAGE`, `NUCEL_AW_ANTHROPIC_SECRET`.
- `ClusterRole` now grants `create` / `get` / `list` on `batch/jobs` and
  `core/secrets` in the CI namespace.
- AppVersion bumped to `0.5.9` to pick up the agent SDK integration.

## 0.1.9 — 2026-05-21

**Commit:** `9df8247` — `feat(chart): wire ANTHROPIC_API_KEY into server and nucel-ci secrets`

- New value `secrets.anthropicApiKey`. When set:
  - `ANTHROPIC_API_KEY` is added to the chart-managed Secret and mounted
    onto the `nucel-server` pod via `secretKeyRef`.
  - A second Secret `nucel-aw-anthropic` is created in
    `.Values.ciNamespace` (default `nucel-ci`) so AW runner Jobs can mount
    it directly.

## 0.1.8 — 2026-05-21

**Commit:** `a6b959c` — `fix(chart): nil-guard cookies/repoStorage/migrations/agentWorkflows`

- Templates no longer error when these top-level keys are unset in an
  overlay (`cookies`, `repoStorage`, `migrations`, `agentWorkflows`).

## 0.1.7 — 2026-05-21

**Commit:** `85c15aa` — `fix(chart): guard serviceAccount and nodePool against nil Values`

- Defensive guards for `serviceAccount` and `nodePool` blocks.

## 0.1.6 — 2026-05-21

**Commit:** `d1add09` — `fix(chart): guard remaining templates against nil Values keys`

- Round of nil-guards across remaining templates.

## 0.1.5 — 2026-05-21

**Commit:** `cea5cab` — `fix(chart): guard all worker template refs against nil .Values.worker`

## 0.1.4 — 2026-05-21

**Commit:** `62e3417` — `fix(chart): properly guard worker-pool range against nil .Values.worker`

## 0.1.3 — 2026-05-21 (appVersion 0.5.3)

**Commit:** `d8558b0` — `chore(chart): bump to 0.1.3 (fix worker-pool nil guard)`

## 0.1.2 — 2026-05-21 (appVersion 0.5.2)

**Commit:** `4c55421` — `chore(chart): bump nucel-server chart to 0.1.2`

## 0.1.1 (skipped — see commits below)

The following changes shipped under what was the active `version: 0.1.0`
line at the time, before the formal version-bump discipline kicked in.
They are listed here for completeness — operators upgrading from a 0.1.0
install pick all of these up when moving to 0.1.2 or later.

- `3f2beb6` — `feat(chart): wire NUCEL_GIT_USER/PASSWORD for AW per-run PAT minting`
  - New values `secrets.gitBotUser` / `secrets.gitBotPassword`.
- `9ef6bb6` — `feat(aw): wire K8s dispatch into Helm chart + fix SA token fallback (#20)`
  - New `agentWorkflows.k8s.*` block (url, namespace, runnerImage, …).
- `dac36b5` — `fix(chart): pin SurrealDB to v3.0.5, add TiKV backend option, gate deploy (Fix C2)`
  - `surrealdb.image` pinned to `surrealdb/surrealdb:v3.0.5`.
  - New `surrealdb.tikvEndpoint`. When non-empty the chart skips the
    `volumeClaimTemplates` block — data lives in TiKV.
  - New `surrealdb.deploy: false` default; production lets Terraform
    `modules/surrealdb` own the StatefulSet.
- `6830629` — `ci(coverage): cache tarpaulin binary + add production values overlay (Fix M10 + M13)`
  - New file `values-production.yaml`.
- `53337f0` — `feat(chart): pre-upgrade migration job + default image tag from AppVersion (Fix M1+M5)`
  - `image.tag` defaults to `""` → falls back to `Chart.AppVersion`.
  - New `migrations.enabled` (default `true`): renders a pre-install /
    pre-upgrade Helm Hook Job that runs `NUCEL_MIGRATE_ONLY=1`. Server
    pods boot with `NUCEL_SKIP_SCHEMA=1` so they don't re-apply the
    schema on every rolling restart.
- `145a4c1` — `feat(chart): OIDC/SSH-host-key required, HPA, PDB, ExternalSecrets, gp3 storage class (Fix C8+C9+H1+H2+H6+H7+H9)`
  - New `secrets.requireProductionValues: true` — `helm install` refuses
    to render when `secrets.oidcPrivateKey` is empty (Fix C8).
  - New `secrets.sshHostKey` — mounted at
    `/etc/nucel/ssh-host-key/NUCEL_SSH_HOST_KEY` (Fix C9).
  - New `secrets.metricsToken` + `prometheus.requireAuth: true` (Fix H9).
  - New `autoscaling.*` block (Fix H1).
  - New `podDisruptionBudget.*` block (Fix H2).
  - New `externalSecrets.*` block (Fix H6).
  - New `storage.storageClassName` (Fix H7 — recommended `gp3` on EKS).
- `418d182` — `feat(chart): ServiceMonitor template for Prometheus discovery (Fix H4)`
  - New `prometheus.serviceMonitor.*` block.
- `b0f1f5b` — `feat(chart): values-driven ingress annotations + IRSA SA support (Fix C7+H5)`
  - `ingress.annotations`, `ingress.className`, `ingress.tls`, and
    `ingress.tlsSecretName` are now first-class values. ALB / nginx
    examples in `values.yaml` comments.
  - `serviceAccount.annotations` for IRSA wiring.
- `4312061` / `53bd0b9` / `6987f3c` / `2c29706` / `a81a30a` / `989f4f1` /
  `1b54240` / `23cd5f8` — Wave M / M2 / Q / V / X / J / AO / AY:
  agent-workflow scheduler knobs — `agentWorkflows.tickPeriodSeconds`,
  `manualTriggerPerMin`, `orgManualTriggerPerMin`, `dailyOrgUsdCap`,
  `needsReviewTtlHours`, `runStuckTimeoutMin`, `autoDisableAfterNFails`,
  `orgMaxConcurrent`.
- `119e832` — `chore(chart): seed Job template, server component label, seed binary in image`
  - New `seed.*` block (fake-data generator).
  - `app.kubernetes.io/component: server` label on the server pod (used
    by the seed Job's podAffinity when `seed.mountRepos: true`).
- `d9fc626` — `fix(server): standard browser security headers + Secure cookie default`
  - New `cookies.secure: "1"` default. Set `"0"` only for local plain-HTTP dev.
- `bc01fda` — `chore(chart): durable arm64 NodePool + metrics + OIDC env wiring`
  - New `nodePool.*` block — durable `arm64-general` Karpenter NodePool
    that EKS Auto Mode does not reconcile.
- `c880a6d` — `feat(storage): T1-9 phase 2 — config-driven backend + Helm S3 wiring`
  - New `repoStorage.*` block. `kind: local` keeps repos on the PVC;
    `kind: s3` enables a cold-tier S3 backend.
- `20b7764` — `feat(jobs): T1-11 claim latency + dispatch counters + alert rules`
  - New `prometheus.alerts.*` block (`PrometheusRule` CRD).
- `c5c5fbd` — `feat(jobs): T1-2 + T1-3 sharded claim + per-kind worker pools`
  - New `worker.pools[]` list with optional `shardIndex`/`shardCount`.
- `8d9993a` — `chore(charts): nucel-worker Deployment template (opt-in)`
  - New `worker.*` block. Off by default.

## 0.1.0 — 2026-04-08 (appVersion 0.1.0)

**Commit:** `f181f88` — `feat: add Helm chart, Justfile, kind dev setup, Docker CI pipeline`

- Initial chart. Renders:
  - `Namespace`, `ConfigMap`, `Secret`, `ServiceAccount`.
  - `Deployment nucel-server` (Axum + SSH).
  - `Service nucel-server` (ClusterIP, http + ssh).
  - `Ingress` (single-host, optional).
  - `PersistentVolumeClaim` ×4 (`nucel-repos`, `nucel-ci-data`,
    `nucel-registry`, `nucel-npm`).
  - `StatefulSet surrealdb` (in-chart SurrealDB, file-backed).
