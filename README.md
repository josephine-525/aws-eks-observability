# observability

Shared platform-monitoring config **and** dashboards-as-code for all teams running on the `demoapp` EKS cluster(s). Same philosophy as [`helm-charts`](https://github.com/josephine-525/aws-eks-helm-charts): the platform owns the shared plumbing, teams own their own content, [`gitops`](https://github.com/josephine-525/aws-eks-gitops-platform) wires the two together. This repo merges what were originally two separate private repos (`observability` + `observability-dashboards`) into one public mirror — the split exists privately because they change at very different rates (the Helm values barely change; dashboards change often), but it isn't worth two public repos for that alone.

## What's here

```
observability/
├── kube-prometheus-stack/
│   └── values.yaml                          # Values for the upstream prometheus-community/kube-prometheus-stack chart
├── teams/
│   └── team-payments/
│       └── team-overview.yaml               # Team-wide rollup dashboard (ConfigMap), hand-authored
└── templates/
    └── standard-microservice-template.jsonnet  # CANONICAL per-service dashboard generator template
```

This repo holds **platform-owned config + centralized dashboard content** — delivered, but not authored service-by-service.

## Delivery

The actual ArgoCD objects live in the `gitops` repo, not here:

- **`kube-prometheus-stack`** Application (multi-source): source 1 is the upstream Helm chart, source 2 is a `ref` to this repo's `values.yaml`. Platform-owned, changes rarely.
- **`observability-dashboards`** Application (plain directory, `directory: { recurse: true }` — ArgoCD does **not** recurse by default, this has to be explicit): syncs this repo's whole `teams/` tree into the `monitoring` namespace's Grafana. **Not** an `ApplicationSet` — there's no per-team/per-service parameterization needed, just "sync this whole directory."

## Why dashboards are centralized here, not in each app's own repo (and what that replaced)

Originally each service repo owned its own dashboard file, delivered by a per-repo `ApplicationSet` element (a List generator, one element per team). That fell apart once a team spans many service repos: a per-service dashboard doesn't compose into a team view, and there's no natural single owner for a team-wide rollup living inside any one service's repo. The fix: dashboard content still *originates* per-service (`idp-cli` scaffolds new services with an optional starter dashboard, same as it scaffolds `values.yaml`), but the generated file lands here, under the team's own directory — not back in the service's repo. A team's cross-service rollup is a first-class file here too, not something bolted onto whichever service happened to exist first.

**Two tiers only — Team Overview and Service Detail — no third org-wide/cost tier.** Considered and deliberately dropped: this platform doesn't have the account-level cost-aggregation or cross-team traffic that would justify one, and adding it now would just be unused structure. When a later addition (service-mesh panels, see below) needed somewhere to go, it went into the existing Team Overview tier rather than reopening this decision.

Each dashboard file is a single `ConfigMap`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <dashboard-name>
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "<Team Display Name>"   # groups dashboards into a Grafana folder
data:
  <dashboard-name>.json: |
    { ...dashboard JSON... }
```

**Folder grouping is a ConfigMap `annotation` (`grafana_folder`), not a field inside the dashboard JSON** — the k8s-sidecar (`k8s-sidecar`, watching `grafana_dashboard: "1"`) reads the annotation to decide which Grafana folder to file the dashboard under; it's not part of Grafana's own dashboard schema.

## How dashboards get here

- **Per-service**: `idp-cli`, when scaffolding a new service with `--dashboard=true` (or via its `/chat` natural-language front end), `git clone`s this repo fresh in its `generate` CI job to fetch `templates/standard-microservice-template.jsonnet` (idp-cli does not vendor its own copy — this is the only one that exists), renders it into a `ConfigMap`, and opens a merge request against this repo directly — a second MR alongside the one it opens against the service's own repo. Editing this template changes what every future scaffold produces immediately, no idp-cli release needed.
- **Team overview**: hand-authored per team — "which panels roll up the whole team" isn't something a scaffolding tool can infer. `teams/team-payments/team-overview.yaml` was migrated from the app's own repo on 2026-09-29, then extended on 2026-10-02 with 4 service-mesh panels (see below).

### Why idp-cli fetches this template live instead of vendoring a copy

Vendoring a copy inside `idp-cli` (e.g. Go's `go:embed`) was tried first, then deliberately reverted — it recreated the exact problem centralizing dashboards elsewhere was meant to solve: two copies of the same file, no enforced sync, and a real question of which one is authoritative if they drifted. Tradeoff accepted knowingly: `idp-cli` is no longer a fully self-contained static binary for this one code path, in exchange for there being exactly one place this template can ever be edited.

### Why Jsonnet, not a Go template, for the per-service generator

Grafana dashboard JSON uses `{{pod}}`/`{{deployment}}`-style template variables — the exact same delimiter Go's `text/template` uses, which used to require an escaping hack (`{{"{{"}}pod{{"}}"}}`) to emit a literal one. Jsonnet's syntax doesn't collide with `{{ }}` at all, so the template emits those strings as plain literals, and conditional panels (e.g. an HPA panel, only when a service has `--has-hpa`) are just array concatenation instead of an `{{if}}` block threaded through JSON.

## Service mesh panels added to `team-payments/team-overview.yaml` (2026-10-02)

Added 4 panels (mTLS connection-security-policy breakdown, response codes, connection failures, circuit-breaker ejection state) once a service mesh (Istio) went into `team-payments` — into the **existing** Team Overview tier, not a new third tier (see "Two tiers only" above; a mesh-specific platform tier was considered and rejected for the same reason the org-wide tier was). Every panel query was checked against a live Prometheus instance before being written, not assumed from Istio's documented metric names — `envoy_cluster_outlier_detection_ejections_active` in particular doesn't exist as a time series at all until a real circuit-breaker ejection has actually happened, so the panel falls back to the raw connection-failure counter instead of a metric that silently reports nothing most of the time.

Getting Prometheus to see these metrics at all required two fixes, not just a `PodMonitor`:
- This cluster's Prometheus Operator ignores any `PodMonitor`/`ServiceMonitor` that doesn't carry the `release: kube-prometheus-stack` label — confirmed via the Operator's own `podMonitorSelector`/`serviceMonitorSelector`, not assumed from the chart's docs.
- Istio's sidecar auto-injection annotates every mesh pod with `prometheus.io/port=15020` — that's the pilot-agent **health** port, not Envoy's actual Prometheus metrics endpoint. The real one is `15090` (`http-envoy-prom`), found by reading the injected pod spec directly rather than trusting the annotation's name.

## What's deliberately NOT here

- **metrics-server** — installed by `gitops`'s bootstrap pipeline as its own Helm release into `kube-system`, not by any app's own CI. Cluster-level capability (feeds `metrics.k8s.io` for HPA), not part of the Prometheus/Grafana stack.
- **Per-service `ServiceMonitor` definitions** — live in the `common-web-service` Helm chart, toggled per-app via each app's own `values.yaml`. Service-owned business logic, not a platform concern. (The mesh-wide `PodMonitor`/istiod `ServiceMonitor` above are the one platform-owned exception, living in `gitops`'s own `istio/monitoring.yaml` — they watch every mesh sidecar cluster-wide, not one app's own metrics.)
- **Explicitly rejected**: a third "Global/org-wide" tier (cross-team aggregation, cloud cost dashboards) — no current need, would be speculative structure; Grafana Operator CRDs (`GrafanaDashboard` custom resources instead of plain `ConfigMap`s) — real value at larger scale (validation, drift detection, multi-Grafana targeting), unjustified complexity here.
