# Attention Report

Attention Report is an optional, default-off observability plugin. It derives a
signed-in operator's deciding, judging, and wasted-attention signals from
existing records. It creates no reporting tables and never exposes another
user's activity.

Enable it under **Admin → Plugins**, then request
`GET /api/v1/app/insights/attention`. `window_days` selects a window from 1 to
90 days and defaults to 7.

The response keeps each inferred rule separate and marks estimates. Agent
runtime and queue wait are reported under `machine_time` and are never included
in attention. Page-time percentiles use active (not elapsed) time collected by
the core **Page engagement telemetry** setting. Visits under three seconds are
dropped, visits are capped at 30 minutes, and samples for the same page subject
within 30 seconds are merged. A page type needs five cleaned visits before p50
or p90 is returned; otherwise the percentile status is `not_enough_data`.

When page engagement telemetry is disabled, `page_time.telemetry_state` is
`off` and no page statistics are returned.
