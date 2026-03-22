# Nucel Helm Charts

Helm chart repository for Nucel products — [charts.nucel.dev](https://charts.nucel.dev)

## Usage

```bash
helm repo add nucel https://nucel-dev.github.io/charts
helm repo update
helm search repo nucel
```

## Available Charts

| Chart | Version | Description |
|-------|---------|-------------|
| [agent-operator](./charts/agent-operator) | 0.1.0 | Kubernetes operator for autonomous AI agent issue resolution |

## Installing a chart

```bash
helm install agent-operator nucel/agent-operator --namespace nucel --create-namespace
```

