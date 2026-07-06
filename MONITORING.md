# Monitoring & Observability — Documentation

## Table of Contents
1. [Stack Overview](#1-stack-overview)
2. [Alerting Rules](#3-alerting-rules)
3. [Dashboards](#4-dashboards)
4. [Tradeoffs & What I'd Do Differently](#5-tradeoffs--what-id-do-differently)
5. [Quick Verification Commands](#6-quick-verification-commands)

---
## Notes
1. I think all Voize's images have been created on ARM systems as I counldn't download images with "no match for platform in manifest" error. My laptop is windows based x64 and I use WSL on it. For this reason I had to enable qemu-user-static package on WSL level and also run multiarch/qemu-user-static container to be able to download images.
2. I had to increase memory limits for ML-API and Backend-API as I faced with error code 137 for both. It might be related to the above point.
3. To save time, I used Gemini/Claude to polish the documentation, review the alert rules, and improve the dashboards layout.
4. Due to lack of hardware resource, Log management solution has not been tested.
   
## 1. Stack Overview

| Component | What it does |
|---|---|
| **kube-prometheus-stack** (Helm + Flux) | Deploys Prometheus, Alertmanager, Grafana, Prometheus Operator, kube-state-metrics, and node-exporter in a single chart |
| **loki** (Helm + Flux) | Log aggregation in single-binary mode — stores all container logs, queryable from Grafana |
| **alloy** (Helm + Flux) | Grafana's next-generation collector (replaces Promtail). Runs as a DaemonSet, discovers pods via the Kubernetes API, and ships their logs to Loki |
| **ServiceMonitor** × 2 | Prometheus Operator CRs that tell Prometheus how to scrape `/metrics` on `ml-api` and `backend-api` every 15 seconds |
| **PrometheusRule** | 18 alerting rules across 4 groups: availability, errors, latency, saturation |
| **Grafana dashboard ConfigMaps** × 2 | Auto-loaded by the Grafana sidecar (label `grafana_dashboard: "1"`): one overview, one deep-dive |

Everything is reconciled by Flux CD. The `infra-configs` Kustomization `dependsOn` the controllers Kustomization so ServiceMonitors and PrometheusRules are only applied after the Prometheus Operator CRDs exist.

---

Prometheus uses **pull-based scraping**: every 15 seconds it reads `/metrics` from every pod matched by a ServiceMonitor. This is why `ServiceTargetDown` (`up == 0`) is a reliable availability signal — if Prometheus cannot reach the pod at all, that metric drops to 0 immediately.

---

## 2. Alerting Rules

All rules live in `infrastructure/configs/alerts/application-alerts.yaml` as a `PrometheusRule` CR in the `monitoring` namespace. They are organized into four groups matching the four golden signals.

### Group: availability

These rules detect whether the services exist and are running at all. They fire before any request-level signal can, which is why they carry the most critical severities.

---

**`ServiceTargetDown`** — severity: critical

```yaml
expr: up{job=~"ml-api|backend-api"} == 0
for: 5m
```

`up` is a synthetic metric Prometheus itself creates: `1` if the last scrape of a target succeeded, `0` if it failed. If either service's pod disappears or becomes unreachable, `up` drops to `0` and the alert fires after 5 minutes. The `for: 5m` window prevents paging during a normal rolling deploy where a pod is briefly unavailable between old and new versions.

---

**`KubePodEnteredBadPhase`** — severity: critical

```yaml
expr: sum(increase(kube_pod_status_phase{job="kube-state-metrics",
        phase!~"Running|Succeeded|Pending"}[2h])) by (namespace, pod, phase) > 2
for: 15m
```

`kube_pod_status_phase` comes from kube-state-metrics and reflects the Kubernetes pod phase. The expression keeps only bad phases (Failed and Unknown) and uses `increase(...[2h])` to count how many times a pod entered one of those phases in the last 2 hours. Threshold `> 2` ignores a single transient failure but alerts if a pod keeps cycling into a bad state. `for: 15m` confirms it is an ongoing problem, not a momentary flap.

---

**`KubePodCrashLoopBackOff`** — severity: critical

```yaml
expr: count(kube_pod_container_status_waiting_reason{
        job="kube-state-metrics", reason="CrashLoopBackOff"} == 1
      ) by (namespace, pod, container, reason) > 0
for: 15m
```

CrashLoopBackOff means Kubernetes is saying "this container keeps crashing, I am backing off before retrying." Rather than counting restarts (which can lag), this reads the live waiting reason directly from kube-state-metrics. Any container in this state for 15 continuous minutes is worth an immediate page — by that point something is structurally broken: bad config, missing secret, unhandled startup error, or a dependency that will never become ready.

---

**`InsufficientReplicas`** — severity: warning

```yaml
expr: kube_deployment_status_replicas_available{namespace=~"ml-api|backend-api"}
      < kube_deployment_spec_replicas{namespace=~"ml-api|backend-api"}
for: 15m
```

Compares what Kubernetes has (`replicas_available`) against what we asked for (`spec_replicas`) for both namespaces. If they are not equal for 15 minutes we are running with reduced capacity — no redundancy, one more pod failure away from a complete outage. Severity is warning rather than critical because one pod is still serving traffic; the alert is a prompt to investigate before it gets worse.

---

### Group: errors

These rules detect that requests are actively failing. They are the most directly user-visible signals.

---

**`MLApiHighErrorRate`** — severity: critical

```yaml
expr: (
    sum(rate(ml_api_requests_total{status=~"5.."}[5m]))
    /
    sum(rate(ml_api_requests_total[5m]))
  ) > 0.05
for: 5m
```

Computes the fraction of ML API requests returning a 5xx response over a 5-minute rolling window and alerts if that fraction exceeds 5% for 5 consecutive minutes. Using a ratio rather than a raw count means the threshold is meaningful regardless of traffic volume — 5% at 10 req/s and 5% at 1000 req/s are equally bad from a user perspective. The `rate()` function smooths over counter resets and rolling deploy gaps.

---

**`BackendApiHighErrorRate`** — severity: critical

```yaml
expr: (
    sum(rate(backend_api_requests_total{status=~"5.."}[5m]))
    /
    sum(rate(backend_api_requests_total[5m]))
  ) > 0.05
for: 5m
```

Same logic applied to the Backend API. The Backend API handles document processing and database writes, so 5xx errors here mean data is not being persisted — often higher direct business impact than ML API latency spikes.

---

**`MLApiNoPredictionsWhileReceivingTraffic`** — severity: critical

```yaml
expr: sum(rate(ml_api_requests_total[10m])) > 0
      and
      sum(rate(ml_api_predictions_total[10m])) == 0
for: 10m
```

This is the most important domain-specific alert. It catches a failure class no other alert would catch: the ML API responding HTTP 200 to every request (so error rate stays 0%) while never actually running inference. The two conditions are combined with `and`: the first confirms traffic is flowing so we do not page on an idle service, the second confirms the business output — predictions — has flatlined. A 10-minute gap between them means the inference pipeline is broken even though the HTTP layer looks healthy.

---

**`BackendApiDbQueryErrors`** — severity: warning

```yaml
expr: (
    sum(rate(backend_api_db_queries_total{status="error"}[5m]))
    /
    sum(rate(backend_api_db_queries_total[5m]))
  ) > 0.02
for: 15m
```

Monitors the ratio of failed database queries against all queries. A 2% threshold is tight by design: a healthy database should produce essentially zero failed queries. The longer `for: 15m` window prevents alerting on brief connection hiccups during a PostgreSQL restart, but catches sustained degradation. This alert often fires before the HTTP error rate alert because DB errors frequently manifest as 500s — catching it here narrows the root cause to the database layer immediately.

---

### Group: latency

These rules detect that the system is serving requests but too slowly. They use histogram metrics so tail latency is visible even when averages look fine.

---

**`MLApiHighLatency`** — severity: warning

```yaml
expr: histogram_quantile(0.95,
        sum(rate(ml_api_request_duration_seconds_bucket[5m])) by (le, endpoint)
      ) > 2
for: 15m
```

`ml_api_request_duration_seconds` is a Prometheus histogram stored as a series of `_bucket` counters, one per configured latency boundary. `rate(..._bucket[5m])` converts each bucket's counter to a per-second rate. `sum(...) by (le, endpoint)` aggregates across replicas while preserving the bucket boundary (`le`) and endpoint labels. `histogram_quantile(0.95, ...)` interpolates across those buckets to estimate the 95th percentile — the latency below which 95% of requests fall.

Threshold is 2 seconds because speech-to-text inference is inherently slow (model loading, audio processing) and a tighter threshold would produce noise on normal operation. `for: 15m` ensures we only alert on sustained slowness, not a brief model cold-start spike.

---

**`BackendApiHighLatency`** — severity: warning

```yaml
expr: histogram_quantile(0.95,
        sum(rate(backend_api_request_duration_seconds_bucket[5m])) by (le, endpoint)
      ) > 1
for: 15m
```

Same structure but threshold is 1 second because Backend API operations (document processing, DB writes) should complete much faster than ML inference. Slow performance here usually points to database lock contention or slow queries.

---

### Group: saturation

These rules detect that resources are running out — leading indicators that fire before errors and latency degrade. The most valuable alerts for proactive intervention.

---

**`BackendApiDbConnectionsNearLimit`** — severity: warning

```yaml
expr: (backend_api_db_connections_active / backend_api_db_connections_max) > 0.85
for: 15m
```

Uses the ratio between active connections and the configured pool maximum, both exposed as application metrics, rather than a hardcoded number. If someone changes the pool size in config the alert automatically adjusts. At 85% utilization for 15 minutes, new requests will start queuing for a connection — showing up as latency first, then errors. This gives an operator time to scale pods or investigate slow queries before that happens.

---

**`MLMemoryGrowth`** — severity: critical

```yaml
expr: predict_linear(ml_api_memory_bytes[1h], 14400)
        > kube_pod_container_resource_limits_memory_bytes{container="ml-api"}
      and
      (ml_api_memory_bytes / kube_pod_container_resource_limits_memory_bytes{container="ml-api"}) > 0.80
for: 15m
```

Two conditions working together. `predict_linear(metric[1h], 14400)` runs linear regression on the last 1 hour of memory samples and projects the value 14400 seconds (4 hours) into the future. If that projected value exceeds the Kubernetes memory limit, the first condition is true. The second condition (`> 0.80`) acts as a floor: we only care about the projection if current usage is already above 80% of the limit, which prevents false positives where memory is low but growing slowly. Both conditions sustained for 15 minutes means the pod is likely leaking memory and will OOMKill within 4 hours — enough time to investigate and act before a crash.

---

**`HighPodMemoryUsage-Warning`** — severity: warning

```yaml
expr: (container_memory_working_set_bytes{container!=""}
       / container_spec_memory_limit_bytes{container!=""}) > 0.70
for: 15m
```

`container_memory_working_set_bytes` (from cAdvisor/kubelet) is the memory the kernel considers actively in use — it excludes reclaimable page cache, making it the number Kubernetes actually uses when deciding whether to OOMKill a container. Dividing by the configured limit gives a utilization ratio. Above 70% for 15 minutes means the container is running hot but still has headroom.

---

**`HighPodMemoryUsage-Critical`** — severity: critical

```yaml
expr: (container_memory_working_set_bytes{container!=""}
       / container_spec_memory_limit_bytes{container!=""}) > 0.90
for: 10m
```

Same metric, higher threshold (90%), shorter `for` duration (10 minutes). At 90% there is very little margin before the OOM killer activates. Requests in-flight at that moment will fail and the pod will restart, losing any in-memory state. The shorter `for` fires faster because the risk of imminent failure is much higher.

---

**`HighPodCPUUsage-warning`** — severity: warning

```yaml
expr: (
    sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) by (namespace, pod, container)
    /
    sum(container_spec_cpu_quota{container!=""} / container_spec_cpu_period{container!=""}) by (namespace, pod, container)
  ) > 0.70
for: 15m
```

`rate(container_cpu_usage_seconds_total[5m])` gives CPU cores currently in use. Dividing by `cpu_quota / cpu_period` gives the configured CPU limit in cores. The ratio shows what fraction of the CPU limit is consumed. Above 70% for 15 minutes means the container is approaching its limit; the Linux CFS scheduler will start throttling it before it reaches 100%, causing latency to rise.

---

**`HighPodCPUUsage-Critical`** — severity: warning ⚠️ *should be critical — see tradeoffs section*

```yaml
expr: same as above but threshold > 0.90
for: 10m
```

At 90% of the CPU limit, CFS throttling is already significant and requests are queueing. The shorter `for` duration triggers faster because the latency impact is already happening.

---

**`HighPVCUsage`** — severity: critical

```yaml
expr: (max by (persistentvolumeclaim, namespace) (
        100 - (kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes) * 100
      ) > 90)
      and
      (max by (persistentvolumeclaim, namespace) (
        kubelet_volume_stats_available_bytes
      ) < 150 * 1024 * 1024 * 1024)
for: 15m
```

Two-condition guard: PVC is more than 90% full **and** has less than 150 GiB of absolute free space. The absolute free space guard prevents false positives on very large volumes — 90% of a 10 TB PVC is still 1 TB free, which is not urgent. With less than 150 GiB free, a PostgreSQL write or WAL segment could fail, causing data loss. Fifteen minutes gives time to expand the PVC or clean up data before writes start failing.

---

**`ContainerCPUThrottlingHigh`** — severity: warning

```yaml
expr: (
    sum(increase(container_cpu_cfs_throttled_periods_total{namespace=~"ml-api|backend-api", container!=""}[5m]))
      by (namespace, pod, container)
    /
    sum(increase(container_cpu_cfs_periods_total{namespace=~"ml-api|backend-api", container!=""}[5m]))
      by (namespace, pod, container)
  ) > 0.20
for: 15m
```

The Linux CFS CPU limiter works in fixed time slices called periods. `container_cpu_cfs_throttled_periods_total` counts how many of those periods a container was throttled — it wanted more CPU than its quota allowed. Dividing by total periods gives the throttle ratio. Above 20% means the container is being held back for more than 1 in 5 scheduling windows, which directly translates into request latency increases that look like application slowness but are actually infrastructure-imposed. When this alert fires alongside `MLApiHighLatency`, it tells you the latency root cause is throttling, not a code bug.

---

### Alert Summary Table

| Alert | Severity | Condition | for |
|---|---|---|---|
| `ServiceTargetDown` | critical | Prometheus cannot scrape the service | 5m |
| `KubePodEnteredBadPhase` | critical | Pod in Failed/Unknown phase more than 2 times in 2h | 15m |
| `KubePodCrashLoopBackOff` | critical | Container waiting reason = CrashLoopBackOff | 15m |
| `InsufficientReplicas` | warning | Available replicas < desired replicas | 15m |
| `MLApiHighErrorRate` | critical | ML API 5xx rate > 5% | 5m |
| `BackendApiHighErrorRate` | critical | Backend API 5xx rate > 5% | 5m |
| `MLApiNoPredictionsWhileReceivingTraffic` | critical | Traffic flowing, zero predictions produced | 10m |
| `BackendApiDbQueryErrors` | warning | DB error query ratio > 2% | 15m |
| `MLApiHighLatency` | warning | ML API p95 latency > 2s | 15m |
| `BackendApiHighLatency` | warning | Backend API p95 latency > 1s | 15m |
| `BackendApiDbConnectionsNearLimit` | warning | DB connections > 85% of pool max | 15m |
| `MLMemoryGrowth` | critical | Linear projection hits limit in <4h AND current usage >80% | 15m |
| `HighPodMemoryUsage-Warning` | warning | Container memory working set > 70% of limit | 15m |
| `HighPodMemoryUsage-Critical` | critical | Container memory working set > 90% of limit | 10m |
| `HighPodCPUUsage-warning` | warning | Container CPU usage > 70% of limit | 15m |
| `HighPodCPUUsage-Critical` | critical | Container CPU usage > 90% of limit | 10m |
| `HighPVCUsage` | critical | PVC >90% full AND <150 GiB free | 15m |
| `ContainerCPUThrottlingHigh` | warning | CPU throttled periods > 20% of total | 15m |

---

## 3. Dashboards

Two dashboards are deployed as Grafana ConfigMaps with label `grafana_dashboard: "1"`, auto-loaded by the Grafana sidecar.

---

### Dashboard 1: Voize Platform — Overview

**File:** `dashboard-voize-overview.yaml`
**Grafana UID:** `voize-overview`
**Time range:** now-1h | **Refresh:** 15s
**Purpose:** Answer "is the system healthy right now?" in under 10 seconds.

#### Row 1 — System Status

| Panel | Metric | Thresholds |
|---|---|---|
| ML API Replicas | `kube_deployment_status_replicas_available{namespace="ml-api"}` | red=0, yellow=1, green≥2 |
| Backend Replicas | `kube_deployment_status_replicas_available{namespace="backend-api"}` | red=0, yellow=1, green≥2 |
| 5xx Error Rate | Combined ML API + Backend API 5xx ratio | green<1%, yellow<5%, red≥5% |
| Predictions / min | `sum(rate(ml_api_predictions_total[5m])) * 60` | red=0, green≥1 |
| Firing Alerts | `count(ALERTS{alertstate="firing", namespace=~"ml-api\|backend-api"})` | green=0, red≥1 |

The replica panels use `kube_deployment_status_replicas_available` rather than the `up` metric because they reflect the Kubernetes desired state — a pod can pass a Prometheus health check but still not count as available if it has not passed the Kubernetes readiness probe.

#### Row 2 — Traffic: Rate, Errors, Duration

Three time-series panels, each showing **both services on the same chart** so cross-service correlation is immediate:

**Request Rate:** Both services on one chart. They should track each other closely since the load generator sends to both. A divergence between lines — one service receiving less traffic than the other — is itself a signal worth investigating.

**5xx Error Rate:** The same 5xx ratio used in the alerting rules, shown as a percentage over time with a red threshold line at 5%. You can see how close to the alert threshold you are, not just whether the alert is currently firing.

**P95 Latency:** Both p50 and p95 for both services, with threshold lines at 1s (yellow) and 2s (red). Showing p50 alongside p95 matters: if they diverge — p50 stays low but p95 spikes — it means only a subset of requests are slow (specific endpoint, pod, or input size), not a global slowdown.

#### Row 3 — Pipeline Health: Inference and Database

**Inference Pipeline — Requests vs Predictions:**

The requests query explicitly excludes `/healthz` and `/metrics` endpoints. This exclusion is deliberate: health checks are not inference requests and including them would inflate the requests line, creating an apparent gap even when inference is working correctly. In a healthy system both lines track each other exactly — every real request produces exactly one prediction. A gap between them is the `MLApiNoPredictionsWhileReceivingTraffic` alert condition made visible.

**Database Query Health — Success vs Error:** Shows `backend_api_db_queries_total` split by status. The error line should be a flat zero. Any upward movement is the `BackendApiDbQueryErrors` alert condition visualized, allowing you to see the error rate trend and the exact moment it started.

#### Row 4 — Kubernetes and Resource Saturation

**Pod Restarts:** `increase(kube_pod_container_status_restarts_total[15m])` per pod — the same lookback window used in `KubePodEnteredBadPhase`, so the chart shows exactly what the alert is reacting to.

**Container Memory — Working Set vs Limit:** Both actual usage and the Kubernetes limit as separate lines per container. The gap between them is the headroom before an OOMKill.

**Backend DB Active Connections:** Per pod, with threshold lines at 85% of the pool maximum — matching the `BackendApiDbConnectionsNearLimit` alert. The threshold line means the chart shows whether you are approaching the alert boundary before it fires.

---

### Dashboard 2: Voize Platform — Technical Backend and ML API

**File:** `dashboard-backend-ml-services.yaml`
**Grafana UID:** `voize-backend-ml-services`
**Time range:** now-30m | **Refresh:** 10s
**Template variables:** `$ml_pod` and `$backend_pod` (multi-select, default All)
**Purpose:** Diagnose exactly what is broken, in which pod, on which endpoint. Used during an active incident after the overview has confirmed something is wrong.

The 30-minute time range gives high-resolution recent data for triage rather than a long history.

#### Template Variables

`$ml_pod` is populated from `label_values(ml_api_requests_total, pod)` and `$backend_pod` from `label_values(backend_api_requests_total, pod)`. Both refresh automatically when pods are added or removed. Selecting a specific pod filters every panel in the corresponding service section to that pod only — essential for identifying a bad replica when others in the pool are healthy.

#### Section: ML API — Traffic and Errors

**Request Rate by Endpoint:** Broken down by endpoint and HTTP method at a 2-minute window (shorter than the 5-minute overview window for higher triage resolution). A sudden drop in traffic to a specific endpoint while `/health` stays up is a key diagnostic signal.

**HTTP Status Breakdown:** Three separate series — 2xx, 4xx, 5xx. Splitting 4xx from 5xx matters: 4xx errors are client-side input problems (not the service's fault), while 5xx errors indicate the service itself is failing. Rising 4xx with stable 5xx may mean a client changed its request format; the inverse means the service is degrading.

#### Section: ML API — Latency

**Latency Percentiles by Endpoint:** p50, p95, and p99 simultaneously per endpoint, with threshold lines at 1s (yellow) and 2s (red). A large gap between p50 and p99 — for example p50 at 200ms and p99 at 5s — means occasional very slow outliers exist, often caused by specific input sizes, cold model caches, or GC pauses, even though most requests are fast.

**P95 Latency per Pod — Hot Pod Detection:** The same p95 calculation grouped by pod instead of endpoint. If one pod is significantly slower than the other the problem is pod-specific — likely bad state, memory pressure, or CPU throttling on that node. This immediately tells you whether to investigate the code or the infrastructure.

#### Section: ML API — Inference Pipeline and Memory

**Inference Health:** Three series — Requests/s, Predictions/s, and a Gap line (requests minus predictions). The gap line should render as flat zero. When it rises, inference is broken. The gap magnitude tells you the exact rate of dropped voice recordings: a gap of 5 req/s means 5 recordings per second are not being processed.

**Application Memory per Pod:** Two series per pod — `ml_api_memory_bytes` (the application's own tracking) and `container_memory_working_set_bytes` (what the kernel reports). Showing both detects discrepancies: if the app reports low memory but the kernel reports high, native library allocations that the Python tracker cannot see may be the cause. Threshold lines at 500 MB (yellow) and 1.5 GB (red) match the `MLMemoryGrowth` alert reference point.

#### Section: Backend API — Traffic and Errors

Mirrors the ML API traffic section, filtered by `$backend_pod`. The Backend API's 5xx errors are frequently correlated with DB errors — if 5xx rises here, check the Database section immediately.

#### Section: Backend API — Latency

Same percentile structure as ML API but with tighter thresholds — yellow at 0.5s, red at 1s — because Backend API operations should be faster than ML inference. Slow endpoints here usually point to slow or blocked database queries.

#### Section: Backend API — Database Layer

**DB Active Connections per Pod:** Per-pod view with threshold lines at 80% and 85% of pool maximum. Per-pod granularity shows whether connection exhaustion is global (all pods at 90%) or pod-specific (one pod holding connections while others are fine — a pattern that often indicates a connection leak in that pod's process).

**DB Query Rate — Success vs Error:** Split by status. The error series should be flat zero. The moment it rises is the start of the `BackendApiDbQueryErrors` alert's lookback window — this chart shows the exact onset and severity of any database degradation.

#### Section: Kubernetes — Container Resources and Pod Health

**Pod Restarts:** Visible alongside all service metrics so you can correlate a latency spike with a restart event on the same timeline.

**CPU Throttling:** `container_cpu_cfs_throttled_seconds_total` rate per pod — the metric behind `ContainerCPUThrottlingHigh`. Non-zero throttling means the OS is actively holding the container back from CPU it needs. This is the infrastructure explanation for latency spikes that have no code-level cause. When this panel is non-zero at the same time as a latency spike, the root cause is the CPU limit, not the application.

**Memory Working Set vs OOM Limit:** Working set and spec limit per container. Lines converging means an OOMKill is imminent.

**Available Replicas vs Desired:** Live view of the `InsufficientReplicas` alert condition. Shows exactly when available dipped below desired relative to all other metrics.

**Container CPU Usage:** CPU utilization rate per pod, behind the `HighPodCPUUsage` alerts. Correlates with the throttling panel — high usage that is also throttled confirms the CPU limit is set too low for the actual workload.

---

## 4. Tradeoffs and What I'd Do Differently

**Alertmanager receiver is a no-op.** In production this would route alerts to Slack/PagerDuty/MS-Teams ....

**No SLO-based burn-rate alerting.** The current rules are static threshold alerts. With more time I would define explicit SLOs — for example, 99.5% of inference requests complete in under 2 seconds over a 30-day rolling window — and use multi-window burn-rate alerts from the Google SRE workbook. Multi-window burn-rate alerts have far fewer false positives than static thresholds and provide graduated urgency: a fast burn (1-hour window) fires as critical, a slow burn (6-hour window) fires as warning.

---

## 5. Quick Verification Commands

```bash
# Check Flux has reconciled everything
flux get kustomizations
flux get helmreleases -n monitoring

# Check all monitoring pods are running
kubectl get pods -n monitoring

# Verify ServiceMonitors exist and Prometheus picked up the targets
kubectl get servicemonitors -A
# Then check Prometheus UI > Status > Targets
# ml-api and backend-api should show State=UP

# Verify PrometheusRule was loaded
kubectl get prometheusrule application-alerts -n monitoring
# Then check Prometheus UI > Status > Rules
# All 18 rules should appear across 4 groups

# Access Prometheus UI
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090

# Access Grafana (credentials: admin / admin — change before real use)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000
# Both dashboards appear under Dashboards > voize

# Verify Loki is receiving logs from Alloy
kubectl -n monitoring port-forward svc/loki 3100:3100
curl http://localhost:3100/ready
```
