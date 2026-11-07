# VictoriaMetrics cluster

This COPS unit is the sole declarative owner of the VictoriaMetrics Kubernetes resources. Its
`k8s.yaml` is rendered from chart `victoria-metrics/victoria-metrics-cluster` version `0.54.0`
and `values.yaml`, with the `victoria-metrics` namespace rendered explicitly. The generated
manifests are committed because the shared COPS chart renderer currently renders resources into
`default` for charts that use `.Release.Namespace`; changing that shared renderer would trigger a
deployment of every COPS unit.

To update the chart or values, render with:

```sh
helm template vmcluster vm/victoria-metrics-cluster \
  --version 0.54.0 --namespace victoria-metrics \
  -f apps/victoria-metrics/values.yaml
```

Keep the image versions in `.env` in sync with the rendered manifests. Do not scale down or delete
the `vmstorage` PVC; its local-path PV reclaim policy is `Delete`.
