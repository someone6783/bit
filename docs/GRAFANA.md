# Prometheus monitoring and Grafana analytics

## Service monitoring

`GET /metrics` is a public Prometheus scrape endpoint for the whole service.
It needs no API key and contains aggregate operational data, with no slugs,
URLs, referrers, API keys or user identifiers. `/metrics/` also works.
Use a network or reverse-proxy access rule if these totals should stay internal.

```yaml
scrape_configs:
  - job_name: bit-service
    metrics_path: /metrics
    static_configs:
      - targets: [short.example.com:443]
    scheme: https
```

```bash
curl http://localhost:4000/metrics
```

| Metric | Type | Meaning |
| --- | --- | --- |
| `bit_links`, `bit_clicks`, `bit_users` | gauge | Current database totals across all users |
| `bit_uptime_seconds` | gauge | Time since this process started |
| `bit_http_requests_total` | counter | Completed requests by `method`, `route` template and HTTP `status` |
| `bit_http_request_duration_seconds` | histogram | HTTP handler duration in seconds, with `_bucket`, `_sum` and `_count` |

Useful PromQL for a five-minute window:

```promql
# Average request time in seconds
rate(bit_http_request_duration_seconds_sum{job="bit-service"}[5m])
/ rate(bit_http_request_duration_seconds_count{job="bit-service"}[5m])

# 95th percentile request time in seconds
histogram_quantile(0.95, rate(bit_http_request_duration_seconds_bucket{job="bit-service"}[5m]))

# Requests per second
sum(rate(bit_http_requests_total{job="bit-service"}[5m]))

# Server errors per second
sum(rate(bit_http_requests_total{job="bit-service",status=~"5.."}[5m]))
```

Request counters and histogram values reset on process restart. Durations use a
monotonic clock, include authentication and error handling, and exclude background
click persistence and network transfer after the handler completes. Service scrapes
are excluded so Prometheus does not inflate traffic or latency statistics. Routes
use templates such as `/:slug` and `/api/links/:id`; unmatched routes and unsupported
methods use fixed labels. Database totals can decrease after deletions; clicks
appear after asynchronous persistence. An idle service has no average latency until
it has served requests. The supplied Prometheus config scrapes service metrics under
`bit-service` and authenticated analytics under `bit`.

## Per-user analytics

`GET /api/metrics` exports persisted click analytics in Prometheus text format.
Authenticate with `X-Api-Key`. Each key sees only its owner's links and clicks,
including the admin key. This endpoint includes per-link and visitor-dimension
labels and is separate from public service monitoring.

## Start the optional monitoring stack

From the repository root, save an existing Bit API key to a local file:

For an existing deployment using the old Compose file, back up the container's
`/usr/src/app/sqlite` directory before rebuilding. The SQLite volume mount now
matches the Dockerfile's working directory; the old `/app/sqlite` mount did not
persist the default database. Restore that backup into `sqlite_data` before
starting the updated app if your data was in the container's writable layer.

```bash
mkdir -p monitoring
read -rs -p 'Bit API key: ' BIT_API_KEY; echo
printf '%s' "$BIT_API_KEY" > monitoring/api-key
unset BIT_API_KEY
chmod 644 monitoring/api-key
export GRAFANA_ADMIN_PASSWORD='choose-a-strong-password'
export ADMIN_API_KEY="$(cat monitoring/api-key)"
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
```

The file must be readable by the Prometheus container's unprivileged user. It is
excluded from Git and the Docker build context. Use the API key of the user whose
analytics you want to view. For the sample Compose app, this is the
`ADMIN_API_KEY` environment variable used by `docker-compose.yml` (required by
upstream's current Compose setup). The original Compose file's application and
data volume are reused.

Open <http://localhost:3000> and sign in as `admin` with the password above.
The **Bit / Bit analytics** dashboard and Prometheus data source are provisioned
automatically. It shows stored link/click totals, scrape health, click totals
over time, and top links, countries, browsers, operating systems, and referrers.
The Prometheus target at <http://localhost:9090/targets> should become UP within
30 seconds. Both monitoring ports are bound to localhost.

The app is built from this checkout; existing published Bit images do not contain
this endpoint. Grafana and Prometheus retain data in named volumes. Prometheus
retains samples for 30 days. Changing `GRAFANA_ADMIN_PASSWORD` after Grafana has
initialized its volume does not reset an existing admin password.

## Use an existing Prometheus / Grafana installation

Add this scrape job to a Prometheus version supporting custom `http_headers`
(the included example uses 3.2.1):

```yaml
scrape_configs:
  - job_name: bit
    scrape_interval: 30s
    metrics_path: /api/metrics
    scheme: https
    http_headers:
      X-Api-Key:
        files: [/etc/prometheus/bit-api-key]
    static_configs:
      - targets: [short.example.com:443]
```

Put the owner's API key in `/etc/prometheus/bit-api-key` on the Prometheus host
(or mount it there). In Grafana, add your Prometheus server as a Prometheus data
source, then import `monitoring/grafana/dashboards/bit.json` and select it using
the dashboard's **Prometheus** dropdown. For multiple users, use separate scrape
jobs with different keys and job names; choose the job in the dashboard. Grafana
access to the Prometheus server grants access to the analytics it has collected.

To check the endpoint directly:

```bash
curl -H "X-Api-Key: YOUR_BIT_API_KEY" http://localhost:4000/api/metrics
```

## Metric semantics

| Metric | Labels | Value |
| --- | --- | --- |
| `bit_links` | none | Stored links owned by the authenticated user |
| `bit_clicks` | none | Stored clicks across that user's links |
| `bit_link_clicks` | `slug` | Stored clicks per short link, including zero-click links |
| `bit_clicks_by_country` | `country` | Stored clicks grouped by country |
| `bit_clicks_by_browser` | `browser` | Stored clicks grouped by browser family |
| `bit_clicks_by_os` | `os` | Stored clicks grouped by OS family |
| `bit_clicks_by_referer` | `referer` | Stored clicks grouped by referrer / `utm_source` |

All metrics are **gauges** of database contents: deleting a link also deletes
its clicks and decreases the totals. Do not apply `rate()` or `increase()` to
these metrics. The dashboard time range shows snapshots collected by Prometheus,
not clicks filtered by their original event dates. Existing database clicks
appear at the first scrape; historical time series begin when scraping starts.

Clicks are written asynchronously and appear after persistence and the next
scrape. Missing dimensions use an empty label value.
Dimensions are exported separately rather than as every possible combination.
Each distinct slug or referrer still creates a series; for large or untrusted
campaign values, drop `bit_clicks_by_referer` with Prometheus
`metric_relabel_configs` if it creates too many series. Scrapes aggregate the
database, so increase the interval for large datasets. Scrapes only read data
and never create clicks.

References: [Prometheus text format](https://prometheus.io/docs/instrumenting/exposition_formats/),
[Prometheus HTTP configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#http_config),
[Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/).
