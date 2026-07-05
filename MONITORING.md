# Monitoring & Observability — Documentation

## 1. What I deployed

| Component | Purpose |
|---|---|
| **kube-prometheus-stack** (Helm, via Flux `HelmRelease`) | Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, Prometheus Operator CRDs |
| **loki-stack** (Helm, via Flux `HelmRelease`) | Loki + Promtail for log aggregation, wired into Grafana as a datasource (optional, but cheap to run and useful for correlating logs with metric spikes) |
| **ServiceMonitor** x2 | Tells Prometheus how to scrape `ml-api` and `backend-api` `/metrics` endpoints |
| **PrometheusRule** | Alerting rules covering availability, errors, latency, and saturation |
| **Grafana dashboard ConfigMap** | "Service Health" dashboard, auto-loaded via the Grafana sidecar (label `grafana_dashboard: "1"`) |

Everything is deployed via GitOps: Flux watches the fork, applies `infrastructure/controllers/monitoring` and `infrastructure/controllers/logging` first (HelmReleases, which also install the Prometheus Operator CRDs), then `infrastructure/configs` (ServiceMonitors/PrometheusRule/dashboard ConfigMap) once the controllers are healthy, via `dependsOn`.

I used the Prometheus Operator (kube-prometheus-stack) rather than hand-rolling a `prometheus.yml` because it gives us CRDs (`ServiceMonitor`, `PrometheusRule`) that let application teams declare their own scrape targets and alerts next to their workloads, without editing a central Prometheus config — which matters for a platform that's expected to grow beyond two services.

## 2. What I chose to monitor, and why

I used the four golden signals as the backbone, applied to each service:

- **Availability** — is the process even up and reachable (`up`, restart counts, replica counts)? This is the cheapest signal to compute and catches the most catastrophic failures (crash loops, OOMKills, bad rollouts) before anything else does.
- **Errors** — 5xx rate as a percentage of total requests, plus DB query error rate on the backend. Ratios rather than raw counts, so the threshold is meaningful regardless of traffic volume.
- **Latency** — p50/p95/p99 request duration per endpoint, since a histogram lets us catch tail latency that an average would hide. ML inference is the most latency-sensitive part of the pipeline (it's on the critical path for every voice recording), so it gets its own, tighter dashboard real-estate.
- **Saturation** — DB connection pool usage and ML API memory growth, both leading indicators that something will break soon even though it hasn't yet.

I also added one domain-specific signal: `MLApiNoPredictionsWhileReceivingTraffic`, which compares request volume against prediction volume. This catches a class of failure that pure HTTP/error-rate monitoring misses entirely — the service responding 200 OK to health checks or even to inference requests while the actual inference logic is silently broken (e.g. a stuck model, a bad dependency, an exception being swallowed before it reaches the metrics middleware).

## 3. Alerts defined

| Alert | Condition | Severity | Why |
|---|---|---|---|
| `ServiceTargetDown` | `up == 0` for 2m | critical | Prometheus can't reach the service at all |
| `PodCrashLooping` | >3 restarts in 15m | critical | Pod is in a crash loop |
| `InsufficientReplicas` | available < desired for 5m | warning | Running with reduced capacity/no redundancy |
| `MLApiHighErrorRate` / `BackendApiHighErrorRate` | 5xx ratio > 5% for 5m | critical | User-facing failures |
| `BackendApiDbQueryErrors` | any `status="error"` DB queries for 5m | warning | DB layer is unhealthy even if HTTP errors haven't shown up yet |
| `MLApiHighLatency` | p95 > 2s for 5m | warning | Inference is slow — directly affects caregiver-facing latency |
| `BackendApiHighLatency` | p95 > 1s for 5m | warning | Document processing is slow |
| `BackendApiDbConnectionsNearLimit` | active connections > 80% of assumed pool size for 5m | warning | Leading indicator of connection exhaustion / request queuing |
| `MLApiMemoryGrowth` | memory > 1.5GiB and trending up for 15m | warning | Possible leak, gives time to act before an OOMKill |
| `MLApiNoPredictionsWhileReceivingTraffic` | requests flowing, zero predictions for 10m | critical | Silent inference-path failure that wouldn't otherwise trip any other alert |

`for:` durations are intentionally set to a few minutes throughout to avoid paging on transient blips (a single slow request, a rolling deploy briefly dropping a replica) while still catching real incidents quickly. Severity (`critical` vs `warning`) is set on the label so Alertmanager routing can be tiered later (e.g. critical → page, warning → Slack channel) — for this case-study cluster, Alertmanager is configured with a no-op receiver since there's no real on-call destination to send to.

## 4. Tradeoffs and what I'd do differently with more time

- **Alertmanager receiver is a no-op.** In a real deployment this would route to Slack/PagerDuty/Opsgenie with severity-based routing trees and silences. I left it as a documented stub rather than wiring up a fake webhook.
- **Connection pool threshold is hardcoded (16/20).** I don't have the actual configured pool size for `backend-api`, so I assumed 20 and alert at 80%. This should be replaced with the real value, or better, exposed as a gauge for max pool size so the alert can compute the ratio dynamically instead of hardcoding it.
- **Prometheus retention is short (6h) and storage is ephemeral**, appropriate for a local k3d case-study cluster but not production — I'd add a `PersistentVolumeClaim` and longer retention (or remote-write to long-term storage like Thanos/Mimir) for a real environment.
- **No SLO-based alerting (multi-window burn rate).** The current rules are simple threshold alerts. With more time I'd define explicit SLOs (e.g. 99.5% of requests < 1s, 99.9% availability) and use multi-window, multi-burn-rate alerts, which catch both fast and slow burns with fewer false positives than static thresholds.
- **Logging is basic.** Loki/Promtail ships raw container logs; I didn't add structured log parsing or log-based metrics. If the services emit structured JSON logs, I'd add Promtail pipeline stages to extract fields (e.g. `request_id`) for correlation with traces/metrics.
- **No distributed tracing.** With three services on a shared request path, OpenTelemetry tracing would make root-causing cross-service latency far easier than dashboards alone. Out of scope for the 4-hour budget, but it's the next thing I'd add.
- **Dashboard is one consolidated view.** For a larger system I'd split this into an overview dashboard plus per-service drill-down dashboards, and add a Kubernetes resource dashboard (CPU/memory per pod) pulled from kube-state-metrics/cAdvisor, which kube-prometheus-stack ships by default but I didn't customize further here.
- **`ServiceMonitor` port name (`http`) and label selector (`app: ml-api` / `app: backend-api`) are assumed** to match the existing Service manifests in `apps/ml-api` and `apps/backend-api`. These need to be checked against the actual Service definitions and adjusted if they differ.

## 5. How to verify it after Flux reconciles

```bash
flux get kustomizations
flux get helmreleases -n monitoring

kubectl -n monitoring get pods
kubectl -n monitoring get servicemonitors -A
kubectl -n monitoring get prometheusrule application-alerts -o yaml

# Prometheus UI - check Status > Targets for ml-api / backend-api
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

# Grafana - default creds admin/admin (change before any real use)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```
