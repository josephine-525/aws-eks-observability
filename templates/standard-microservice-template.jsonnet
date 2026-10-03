// CANONICAL COPY — this is the ONLY copy of this template anywhere.
// idp-cli does NOT embed or vendor its own; its generate CI job git-clones
// this repo fresh on every run and reads this file directly (see
// idp-cli/dashboard.go and .gitlab-ci.yml). Edit this file to change what
// every newly-scaffolded per-service dashboard looks like — there is no
// second copy to keep in sync, and no build step in idp-cli to re-run.
//
// A function that produces one service's Grafana dashboard, as a plain
// Jsonnet object -- serialized to JSON by the caller (idp-cli/dashboard.go).
//
// Why Jsonnet, not Go's text/template (what this replaced): Grafana's own
// dashboard variables use the exact same {{ }} syntax as Go templates, so
// the old version needed an escape hack to output a literal "{{pod}}"
// (`{{"{{"}}pod{{"}}"}}`  in dashboard.go's old source). Jsonnet's syntax
// doesn't collide with `{{ }}` at all -- "{{pod}}" below is just a literal
// string, no escaping needed. Conditionally including the HPA panel is
// also plain array concatenation (`+`) instead of an `{{if}}` block
// threaded through the middle of a JSON string.
//
// No grafonnet (the community Jsonnet library for Grafana) -- this doesn't
// need its abstractions, and pulling it in means vendoring a library via
// jsonnet-bundler for one template. Plain object literals matching
// Grafana's own dashboard JSON schema directly are enough here.
function(name, team, hasHPA=false)
  local deployment = name + '-common-web-service';

  local basePanels = [
    {
      id: 1,
      title: 'CPU usage (cores)',
      type: 'timeseries',
      datasource: { type: 'prometheus', uid: '${datasource}' },
      gridPos: { x: 0, y: 0, w: 12, h: 8 },
      fieldConfig: { defaults: { unit: 'short' }, overrides: [] },
      targets: [{
        datasource: { type: 'prometheus', uid: '${datasource}' },
        expr: 'sum(rate(container_cpu_usage_seconds_total{namespace="%s", pod=~"%s-.*", container!="", container!="POD"}[5m])) by (pod)' % [team, deployment],
        legendFormat: '{{pod}}',
      }],
    },
    {
      id: 2,
      title: 'Memory working set',
      type: 'timeseries',
      datasource: { type: 'prometheus', uid: '${datasource}' },
      gridPos: { x: 12, y: 0, w: 12, h: 8 },
      fieldConfig: { defaults: { unit: 'bytes' }, overrides: [] },
      targets: [{
        datasource: { type: 'prometheus', uid: '${datasource}' },
        expr: 'sum(container_memory_working_set_bytes{namespace="%s", pod=~"%s-.*", container!="", container!="POD"}) by (pod)' % [team, deployment],
        legendFormat: '{{pod}}',
      }],
    },
    {
      id: 3,
      title: 'Container restarts (last 1h)',
      type: 'timeseries',
      datasource: { type: 'prometheus', uid: '${datasource}' },
      gridPos: { x: 0, y: 8, w: 12, h: 8 },
      fieldConfig: { defaults: { unit: 'short' }, overrides: [] },
      targets: [{
        datasource: { type: 'prometheus', uid: '${datasource}' },
        expr: 'sum(increase(kube_pod_container_status_restarts_total{namespace="%s", pod=~"%s-.*"}[1h])) by (pod)' % [team, deployment],
        legendFormat: '{{pod}}',
      }],
    },
    {
      id: 4,
      title: 'Pods available',
      type: 'timeseries',
      datasource: { type: 'prometheus', uid: '${datasource}' },
      gridPos: { x: 12, y: 8, w: 12, h: 8 },
      fieldConfig: { defaults: { unit: 'short' }, overrides: [] },
      targets: [{
        datasource: { type: 'prometheus', uid: '${datasource}' },
        expr: 'kube_deployment_status_replicas_available{namespace="%s", deployment="%s"}' % [team, deployment],
        legendFormat: '{{deployment}}',
      }],
    },
  ];

  local hpaPanel = {
    id: 5,
    title: 'HPA CPU utilization vs target',
    type: 'timeseries',
    datasource: { type: 'prometheus', uid: '${datasource}' },
    gridPos: { x: 0, y: 16, w: 12, h: 8 },
    fieldConfig: { defaults: { unit: 'percent' }, overrides: [] },
    targets: [
      {
        datasource: { type: 'prometheus', uid: '${datasource}' },
        expr: 'kube_horizontalpodautoscaler_status_target_metric{namespace="%s", horizontalpodautoscaler="%s", metric_target_type="utilization"}' % [team, deployment],
        legendFormat: 'current',
      },
      {
        datasource: { type: 'prometheus', uid: '${datasource}' },
        expr: 'kube_horizontalpodautoscaler_spec_target_metric{namespace="%s", horizontalpodautoscaler="%s", metric_target_type="utilization"}' % [team, deployment],
        legendFormat: 'target',
      },
    ],
  };

  {
    uid: name + '-overview',
    title: name,
    tags: [team],
    timezone: '',
    schemaVersion: 39,
    refresh: '10s',
    time: { from: 'now-1h', to: 'now' },
    templating: {
      list: [{
        name: 'datasource',
        label: 'Data source',
        type: 'datasource',
        query: 'prometheus',
        current: { text: 'default', value: 'default', selected: true },
        hide: 0,
        regex: '',
      }],
    },
    panels: basePanels + (if hasHPA then [hpaPanel] else []),
  }
