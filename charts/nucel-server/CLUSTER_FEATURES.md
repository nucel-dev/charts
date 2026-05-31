# Cluster Feature Audit — `nucel` namespace on `neoconto`

> Lives in the chart directory because the repo's top-level `docs/`
> is gitignored.

Live audit of `https://nucel.neoconto.com` (context `neoconto`, namespace `nucel`,
release `nucel`, chart `nucel-server-0.1.23` running app `0.5.17` at audit time).

Each row tracks a feature whose backend code is shipped but whose effect was
silently disabled in the live cluster because a Helm value, Secret, or both were
unset. Status legend:

- `[ok]`  — wired up; feature is active after the next `helm upgrade`.
- `[fix]` — chart change shipped in this audit; needs `helm upgrade` to roll.
- `[op]`  — chart already shipped wiring; **operator action required**
              (set Helm value or create K8s Secret manually). No chart change.
- `[def]` — deferred / owned by another agent / out of scope.
- `[rust]` — Rust bug, not a chart issue. Filed for follow-up.

## Findings

| # | Pod log WARN (verbatim, trimmed) | Status | Disposition |
|---|---|---|---|
| 1 | `nucel_server::email: NUCEL_SMTP_URL is unset — email backend running in no-op mode. Verification + password-reset tokens will be logged but no email sent.` | `[op]` | Chart already renders a `<release>-email` Secret + wires `NUCEL_SMTP_URL` into the deployment with `optional: true`. Operator must set `email.smtpUrl` (or create the Secret manually — see "Operator actions" below). |
| 2 | `nucel_server: Docker unavailable (Docker error: Socket not found: /var/run/docker.sock); CI worker loop disabled. K8s dispatch is configured but the worker poll loop also requires Docker today — CI will be inert until Docker is reachable or the worker is split out.` | `[def]` | Owned by parallel agent (#226 — decoupling CI worker loop from Docker). No chart change in this audit. |
| 3 | `nucel_server: SSH server failed to start: No such file or directory (os error 2)` | `[fix]` | Chart's secret template was waiting on operator to set `secrets.sshHostKey`. Now auto-generates an Ed25519 PKCS#8 PEM via Helm's `genPrivateKey "ed25519"` on first install and pins the value via `lookup` on every subsequent upgrade. `russh-keys 0.46` accepts the format natively (see `crates/nucel-server/src/ssh/mod.rs::load_or_generate_host_key`). |
| 4 | `nucel_server::agent_runner: claude binary not found; skipping local-adapter heartbeat agent_id=…` | `[op]` | The local-adapter path expects a `claude` CLI on the server pod's `$PATH`. Production AW dispatch already uses the K8s runner pod path (`NUCEL_AW_K8S_URL` is set), so this heartbeat is purely the in-process fallback. Operator action: leave disabled OR build a server image variant that includes the `claude` CLI binary. Documented as "expected on this cluster". |
| 5 | `nucel_server::handlers::auth: failed to mint verification token: 'token' is a protected variable and cannot be set` | `[rust]` | SurrealDB v3 reserves the `$token` parameter name. Not a chart issue. Filed for handler rewrite — `crates/nucel-server/src/handlers/auth/mod.rs` is using `token` as a SurrealDB query parameter; needs to rename to e.g. `verify_token`. Until then, signups silently fail to mint verification tokens (orthogonal to whether SMTP is wired). |

Additional non-WARN gap surfaced by the audit:

| # | Gap | Status | Disposition |
|---|---|---|---|
| 6 | `pagesStorage.kind: fs` with `server.replicas: 2` — 50% 404 race on every pages asset request (only the pod that ran `deploy_pages` has the bytes; the other pod 404s). The race was diagnosed and the `s3` backend shipped in 660d92e, but the live cluster overlay never flipped the kind. | `[op]` | Chart side: configmap now provides repoStorage→pagesStorage S3 bucket fallback so operator can re-use the existing repo bucket with a different prefix. Operator action: set `pagesStorage.kind=s3` + `pagesStorage.s3.bucket=…` + `pagesStorage.s3.region=eu-south-2` in the cluster overlay. |

## Operator actions

### 1. SMTP (SES eu-south-2)

```bash
# In AWS IAM, either:
#   - find an existing SES SMTP user, OR
#   - create a new one: aws iam create-user --user-name ses-smtp-nucel
#     then aws ses create-smtp-credentials… (or use the SES console "Create SMTP
#     credentials" button, which wraps the IAM access-key → SMTP-password derivation).

# URL-encode any '/' or '+' in the SMTP password — SES passwords frequently
# contain both. The URL parser is strict.

# Roll via Helm:
helm --kube-context=neoconto -n nucel upgrade nucel charts/nucel-server \
  --reuse-values \
  --set "email.smtpUrl=smtp://AKIA…:URL_ENCODED_PASSWORD@email-smtp.eu-south-2.amazonaws.com:587" \
  --set "email.from=Nucel <no-reply@nucel.neoconto.com>" \
  --set "email.baseUrl=https://nucel.neoconto.com"
```

Notes:
- Use `smtp://` for STARTTLS on port `587` (SES recommended). `smtps://` is for
  implicit TLS on port `465`.
- The `from` domain must be SES-verified.

### 2. SSH host key

No operator action — the chart now auto-generates an Ed25519 key on first
`helm upgrade` after this audit lands. The key is persisted in the existing
`nucel-nucel-server-secrets` Secret under `NUCEL_SSH_HOST_KEY` and carried
forward verbatim on every subsequent upgrade.

To override with an out-of-band-managed key:

```bash
ssh-keygen -t ed25519 -N "" -f /tmp/nucel-ssh-host -C "nucel-ssh-host"

helm --kube-context=neoconto -n nucel upgrade nucel charts/nucel-server \
  --reuse-values \
  --set-file "secrets.sshHostKey=/tmp/nucel-ssh-host"

rm /tmp/nucel-ssh-host  # don't keep the private key on disk
```

### 3. Pages storage → S3

The cluster runs `server.replicas: 2` but `pagesStorage.kind: fs` — every other
pages request 404s because only the pod that built the site has the files.

```bash
# Either create a dedicated bucket OR re-use the repo bucket with a prefix.
# The chart auto-falls-back on bucket when pagesStorage.s3.bucket is empty.

helm --kube-context=neoconto -n nucel upgrade nucel charts/nucel-server \
  --reuse-values \
  --set "pagesStorage.kind=s3" \
  --set "pagesStorage.s3.bucket=nucel-neoconto-pages" \
  --set "pagesStorage.s3.region=eu-south-2" \
  --set "pagesStorage.s3.prefix=pages/"
```

If using IRSA (recommended on EKS), no `accessKeyId`/`secretAccessKey` is
needed — the pod's mounted ServiceAccount token authenticates to S3.

## What's still silently disabled

- `[def]` CI worker loop (Docker socket) — agent #226 owns the decoupling.
- `[op]`  SMTP — needs operator action; chart is ready.
- `[op]`  Pages → S3 — needs operator action; chart is ready.
- `[op]`  `claude` CLI local-adapter heartbeat — design call; K8s dispatch is
            the production path on this cluster.
- `[rust]` Signup verification token mint (`'token' is protected`) — needs Rust
            fix in `handlers/auth/mod.rs`.

After the operator actions above land, the only WARN that should still appear
on every pod startup is the Docker one (deferred to #226).
