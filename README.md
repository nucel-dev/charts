# Nucel Helm Charts

Helm chart repository for Nucel products — [charts.nucel.dev](https://charts.nucel.dev)

## Usage

```bash
helm repo add nucel https://charts.nucel.dev
helm repo update
helm search repo nucel
```

## Available Charts

| Chart | Version | App Version | Description |
|-------|---------|-------------|-------------|
| nucel-server   | 0.1.38 | 0.5.27 | Self-hosted git platform with built-in CI/CD, container registry, and AI agent orchestration. |
| agent-operator | 0.2.0  | 0.1.0  | Kubernetes operator for autonomous AI agent issue resolution. |
| nucel-web      | 0.1.0  | 0.1.3  | Marketing site (SvelteKit) for nucel. |

## Installing a chart

```bash
# nucel-server (latest)
helm install nucel nucel/nucel-server \
  --namespace nucel --create-namespace

# agent-operator
helm install agent-operator nucel/agent-operator \
  --namespace nucel --create-namespace

# nucel-web
helm install nucel-web nucel/nucel-web \
  --namespace nucel --create-namespace
```

### Pinning a specific version

```bash
helm search repo nucel/nucel-server --versions
helm install nucel nucel/nucel-server --version 0.1.29
```

## Release flow

Charts are published automatically by [`helm/chart-releaser-action`](https://github.com/helm/chart-releaser-action)
on every push to `main`:

1. Edit chart source under `charts/<chart-name>/` and bump `version` in `Chart.yaml`.
2. Commit + push to `main`.
3. CI runs `cr package` + `cr upload` + `cr index` — a GitHub Release is created with the
   `.tgz` attached, and `index.yaml` is updated on the `gh-pages` branch.

> Do NOT commit packaged `.tgz` files or hand-edit `index.yaml` — CI owns those
> artefacts (they live on the `gh-pages` branch). The root `.gitignore` blocks
> them from `main`.

## CI

Two workflows guard the repo:

- **`lint.yml`** (PRs + pushes to `main` touching `charts/**`) — `helm lint`
  every chart, then `helm template` smoke renders for nucel-server (relaxed-dev,
  production-values, and full-HA shapes) and agent-operator (default + HA),
  plus a secret-literal assertion that fails if any operator-provided secret
  renders with a baked-in value. This catches chart regressions before release.
- **`release.yml`** (pushes to `main`) — `helm/chart-releaser-action` packages,
  uploads, and re-indexes. `skip_existing: true` keeps it idempotent so a push
  touching one chart doesn't 422 on the others' already-published releases.

## Production hardening (nucel-server)

See [`charts/nucel-server/PRODUCTION_HARDENING.md`](./charts/nucel-server/PRODUCTION_HARDENING.md)
for the required-values guard, secret generation, and post-install verification checklist.
