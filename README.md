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
| [nucel-server](./charts/nucel-server)   | 0.1.15 | 0.5.9 | Self-hosted git platform with built-in CI/CD, container registry, and AI agent orchestration. |
| [agent-operator](./charts/agent-operator) | 0.1.0  | 0.1.0 | Kubernetes operator for autonomous AI agent issue resolution. |

## Installing a chart

```bash
# nucel-server (latest)
helm install nucel-server nucel/nucel-server --version 0.1.15 \
  --namespace nucel --create-namespace

# agent-operator
helm install agent-operator nucel/agent-operator --version 0.1.0 \
  --namespace nucel --create-namespace
```

### Pinning a specific version

```bash
helm search repo nucel/nucel-server --versions
helm install nucel-server nucel/nucel-server --version 0.1.15
```

## Release flow

Charts are published automatically by [`helm/chart-releaser-action`](https://github.com/helm/chart-releaser-action)
on every push to `main`:

1. Edit chart source under `charts/<chart-name>/` and bump `version` in `Chart.yaml`.
2. Commit + push to `main`.
3. CI runs `cr package` + `cr upload` + `cr index` — a GitHub Release is created with the
   `.tgz` attached, and `index.yaml` is updated on the `gh-pages` branch.

> Do NOT commit packaged `.tgz` files or hand-edit `index.yaml` — CI owns those artefacts.

## Production hardening (nucel-server)

See [`charts/nucel-server/PRODUCTION_HARDENING.md`](./charts/nucel-server/PRODUCTION_HARDENING.md)
for the required-values guard, secret generation, and post-install verification checklist.
