# agent-operator Helm Chart

Kubernetes operator that drives AI agents to autonomously fix GitHub/Jira issues.

## Components

| Component | Description | Deployed by Helm? |
|-----------|-------------|-------------------|
| **Operator** | Watches AgentTask CRDs, runs phase machine, spawns worker Jobs | Yes |
| **Webhook** | HTTP server receiving GitHub/Jira webhooks, creates AgentTask CRDs | Yes |
| **Worker** | Runs inside K8s Jobs spawned by the operator | No (operator creates these) |

## Quick Install

```bash
helm install agent-operator ./charts/agent-operator \
  --namespace agent-operator-system \
  --create-namespace \
  --set secrets.anthropicApiKey=sk-ant-... \
  --set secrets.githubToken=ghp_...
```

## Values Reference

### Image

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `agent-operator` | Base image repository name |
| `image.tag` | `latest` | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |

### Operator

| Key | Default | Description |
|-----|---------|-------------|
| `operator.replicas` | `1` | Number of operator replicas |
| `operator.resources.requests.cpu` | `100m` | CPU request |
| `operator.resources.requests.memory` | `128Mi` | Memory request |
| `operator.resources.limits.cpu` | `500m` | CPU limit |
| `operator.resources.limits.memory` | `256Mi` | Memory limit |

### Webhook

| Key | Default | Description |
|-----|---------|-------------|
| `webhook.replicas` | `1` | Number of webhook replicas |
| `webhook.resources.requests.cpu` | `100m` | CPU request |
| `webhook.resources.requests.memory` | `128Mi` | Memory request |
| `webhook.resources.limits.cpu` | `500m` | CPU limit |
| `webhook.resources.limits.memory` | `256Mi` | Memory limit |
| `webhook.service.type` | `ClusterIP` | Service type |
| `webhook.service.port` | `8080` | Service port |

### Worker

| Key | Default | Description |
|-----|---------|-------------|
| `worker.image.repository` | `""` | Worker image repo (defaults to `image.repository`) |
| `worker.image.tag` | `""` | Worker image tag (defaults to `image.tag`) |
| `worker.resources.requests.cpu` | `500m` | CPU request for worker Jobs |
| `worker.resources.requests.memory` | `512Mi` | Memory request for worker Jobs |
| `worker.resources.limits.cpu` | `2` | CPU limit for worker Jobs |
| `worker.resources.limits.memory` | `2Gi` | Memory limit for worker Jobs |

### Ingress

| Key | Default | Description |
|-----|---------|-------------|
| `ingress.enabled` | `false` | Enable ingress for webhook |
| `ingress.className` | `""` | Ingress class name |
| `ingress.annotations` | `{}` | Ingress annotations |
| `ingress.hosts` | see values.yaml | Ingress host rules |
| `ingress.tls` | `[]` | TLS configuration |

### Secrets

| Key | Default | Description |
|-----|---------|-------------|
| `secrets.create` | `true` | Create secrets (set false to manage externally) |
| `secrets.githubAppId` | `""` | GitHub App ID |
| `secrets.githubAppPrivateKey` | `""` | GitHub App private key (base64-encoded PEM) |
| `secrets.githubAppInstallationId` | `""` | GitHub App installation ID |
| `secrets.githubToken` | `""` | GitHub PAT (for `auth: pat` mode) |
| `secrets.anthropicApiKey` | `""` | Anthropic API key |
| `secrets.webhookApiToken` | `""` | Webhook API bearer token |
| `secrets.githubWebhookSecret` | `""` | GitHub webhook HMAC secret |
| `secrets.jiraWebhookSecret` | `""` | Jira webhook secret |

### Namespace & CRD

| Key | Default | Description |
|-----|---------|-------------|
| `namespace.create` | `true` | Create the namespace |
| `namespace.name` | `agent-operator-system` | Target namespace |
| `crd.install` | `true` | Install the AgentTask CRD |

### Operator Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `config.providers.git` | `github` | Git provider |
| `config.providers.issues` | `github` | Issue tracker |
| `config.providers.knowledge` | `none` | Knowledge base |
| `config.providers.agent` | `claude` | AI agent |
| `config.providers.ci` | `github-actions` | CI system |
| `config.providers.secrets` | `env` | Secret store |
| `config.providers.workspace` | `notify-only` | Escalation workspace |
| `config.github.auth` | `app` | GitHub auth mode (`app` or `pat`) |
| `config.notifications.channels` | `[]` | Notification channels |
| `config.concurrency.maxConcurrentTasks` | `5` | Max concurrent tasks |
| `config.concurrency.maxTasksPerRepo` | `2` | Max tasks per repo |
| `config.escalation.enabled` | `false` | Enable human escalation |
| `config.defaults.model` | `claude-opus-4-6` | Default AI model |
| `config.defaults.maxBudgetUsd` | `5.0` | Max spend per task (USD) |
| `config.defaults.maxLocalAttempts` | `3` | Max local test-fix iterations |
| `config.defaults.maxCiAttempts` | `3` | Max CI fix iterations |
| `config.defaults.priority` | `medium` | Default task priority |

### Monitoring

| Key | Default | Description |
|-----|---------|-------------|
| `monitoring.serviceMonitor.enabled` | `false` | Create ServiceMonitor resources for Prometheus Operator |
| `monitoring.serviceMonitor.interval` | `30s` | Scrape interval for metrics |
| `monitoring.serviceMonitor.labels` | `{}` | Additional labels for the ServiceMonitor (e.g. `release: prometheus`) |
| `monitoring.serviceMonitor.namespace` | `""` | Namespace for ServiceMonitor (defaults to release namespace) |
| `monitoring.grafana.dashboards.enabled` | `false` | Create ConfigMaps for Grafana dashboard sidecar auto-provisioning |
| `monitoring.grafana.dashboards.label` | `grafana_dashboard` | Label key that Grafana sidecar watches for |
| `monitoring.grafana.dashboards.labelValue` | `"1"` | Label value that Grafana sidecar matches |

## Monitoring

### Enabling Prometheus ServiceMonitor

If you are using the [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator),
enable the ServiceMonitor to have Prometheus automatically scrape the operator and webhook metrics:

```bash
helm install agent-operator ./charts/agent-operator \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.serviceMonitor.labels.release=prometheus
```

This creates two `ServiceMonitor` resources:
- **agent-operator-operator** -- scrapes `/metrics` on port 9090 from the operator
- **agent-operator-webhook** -- scrapes `/metrics` on port 8080 from the webhook

### Enabling Grafana Dashboards

If your Grafana instance uses the [sidecar dashboard provisioner](https://github.com/grafana/helm-charts/tree/main/charts/grafana#sidecar-for-dashboards),
enable dashboard auto-provisioning:

```bash
helm install agent-operator ./charts/agent-operator \
  --set monitoring.grafana.dashboards.enabled=true
```

This creates one ConfigMap per dashboard, each labeled with `grafana_dashboard: "1"` so the
Grafana sidecar picks them up automatically. Three dashboards are included:

| Dashboard | File | Description |
|-----------|------|-------------|
| **Agent Operator - Overview** | `overview.json` | Task throughput, active tasks, phase distribution, P95 durations, cost per repo, success rate |
| **Agent Operator - Webhooks** | `webhook.json` | Request rate by source/event, latency percentiles (P50/P95/P99), error rate, requests by source |
| **Agent Operator - Costs** | `costs.json` | Daily cost by repo, cost by model, budget utilization, test/CI attempts, average cost per task |

All dashboards use an `__inputs` datasource variable so you can select the correct Prometheus
datasource when importing. Each dashboard includes a `$namespace` template variable for filtering.

### Full Monitoring Stack Example

```bash
helm install agent-operator ./charts/agent-operator \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.serviceMonitor.labels.release=prometheus \
  --set monitoring.grafana.dashboards.enabled=true \
  --set secrets.anthropicApiKey=sk-ant-... \
  --set secrets.githubToken=ghp_...
```

## Examples

### Minimal Install (PAT mode, local dev)

```bash
helm install agent-operator ./charts/agent-operator \
  --set config.github.auth=pat \
  --set secrets.githubToken=ghp_your_token \
  --set secrets.anthropicApiKey=sk-ant-your_key \
  --set secrets.webhookApiToken=my-api-token \
  --set secrets.githubWebhookSecret=my-webhook-secret
```

### Production (GitHub App + Ingress)

```bash
helm install agent-operator ./charts/agent-operator \
  --namespace agent-operator-system \
  --set secrets.githubAppId=123456 \
  --set secrets.githubAppPrivateKey="$(base64 < app.pem)" \
  --set secrets.githubAppInstallationId=78901234 \
  --set secrets.anthropicApiKey=sk-ant-prod-key \
  --set secrets.webhookApiToken=secure-token \
  --set secrets.githubWebhookSecret=webhook-hmac-secret \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.hosts[0].host=agent-operator.example.com \
  --set ingress.hosts[0].paths[0].path=/ \
  --set ingress.hosts[0].paths[0].pathType=Prefix \
  --set ingress.tls[0].secretName=agent-operator-tls \
  --set ingress.tls[0].hosts[0]=agent-operator.example.com
```

### Custom Resource Limits

```bash
helm install agent-operator ./charts/agent-operator \
  --set operator.resources.limits.cpu=1 \
  --set operator.resources.limits.memory=512Mi \
  --set worker.resources.limits.cpu=4 \
  --set worker.resources.limits.memory=4Gi \
  --set config.concurrency.maxConcurrentTasks=10
```

### Minikube (local image, no pull)

```bash
# Build inside minikube's Docker daemon
eval $(minikube docker-env)
docker build -t agent-operator-operator:latest -t agent-operator-worker:latest -t agent-operator-webhook:latest .

helm install agent-operator ./charts/agent-operator \
  --set image.pullPolicy=Never \
  --set config.github.auth=pat \
  --set secrets.githubToken=ghp_your_token \
  --set secrets.anthropicApiKey=sk-ant-your_key \
  --set secrets.webhookApiToken=dev-token \
  --set secrets.githubWebhookSecret=dev-secret
```
