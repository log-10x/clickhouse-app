# tenx-for-clickhouse Helm chart

Applies the `tenx-for-clickhouse` SQL schema (templates table, dictionary, expansion UDFs, expansion views) to an **existing** ClickHouse service via a one-shot Kubernetes Job.

This chart does **not** install ClickHouse itself. It assumes you already have a working ClickHouse cluster reachable from your Kubernetes cluster (Altinity operator, Bitnami chart, ClickHouse Cloud, or a self-managed deployment).

## Install

```bash
helm install my-tenx ./helm/tenx-for-clickhouse \
  --set clickhouse.host=my-clickhouse.namespace.svc.cluster.local \
  --set clickhouse.port=8123 \
  --set clickhouse.user=default \
  --set clickhouse.password=...
```

Or with values from an existing Kubernetes Secret (recommended for production):

```bash
kubectl create secret generic ch-creds \
  --from-literal=user=default \
  --from-literal=password=...

helm install my-tenx ./helm/tenx-for-clickhouse \
  --set clickhouse.host=my-clickhouse.namespace.svc.cluster.local \
  --set clickhouse.existingSecret=ch-creds
```

## What it does

1. Renders `tenx-for-clickhouse/install.sql` into a ConfigMap.
2. Spawns a one-shot Job that mounts the SQL file and runs `clickhouse-client --multiquery < /sql/install.sql` against your ClickHouse endpoint.
3. If `job.runHealthCheck` is enabled, runs four sanity queries to verify the install.

## Values

See [values.yaml](values.yaml). Key fields:

| Field | Default | Description |
|---|---|---|
| `clickhouse.host` | `clickhouse.clickhouse.svc.cluster.local` | DNS name of your CH service |
| `clickhouse.port` | `8123` | HTTP port (use 9000 if you prefer native protocol) |
| `clickhouse.secure` | `false` | Set to `true` for HTTPS / TLS (e.g. CH Cloud) |
| `clickhouse.user` | `default` | Username (inline; prefer `existingSecret`) |
| `clickhouse.password` | `""` | Password (inline; prefer `existingSecret`) |
| `clickhouse.existingSecret` | `""` | Name of a Secret with `user` and `password` keys |
| `job.image.tag` | `latest` | Image tag for the install runner |
| `job.runHealthCheck` | `true` | Run sanity queries after install |

## Status

This is a **v0.1.0 starter chart** intended to be the easiest possible path for K8s users. It does not (yet) bundle a Helm sub-chart for ClickHouse itself, manage upgrades across schema versions, or expose Prometheus metrics. PRs welcome.

For non-K8s installs, see the main [USER-GUIDE.md](../../USER-GUIDE.md).
