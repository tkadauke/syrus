# Operations calendar

The disableable Calendar plugin provides a read-only week and agenda view at `/calendar`. It combines planned work with observed execution state while keeping editing and remediation in the owning feature.

## Event-source extension

A plugin may optionally depend on `calendar` and contribute a provider under `"calendar:event_source"`. Providers implement `calendar_events(user:, starts_at:, ends_at:)` and **must authorize before querying**; returning global data for Calendar to filter is not supported. Queries always have a bounded range (at most 42 days).

Each result supplies stable namespaced `source_id` and `id` values, `kind`, `title`, `starts_at`, `destination_path`, and `state`. It may also supply `ends_at`, actual start/finish timestamps, cadence metadata, and source-specific `metadata`. A provider can expose `estimated_duration_seconds` together with `duration_estimate_provenance` (`representative` or `source`) without coupling Calendar to the provider's records. Calendar validates results, instruments provider calls, and isolates failures so one source cannot remove the rest of the calendar.

Built-in sources show pending chat wakeups only to their owner. Administrators additionally see recurring Solid Queue maintenance definitions and recent observable execution health, including failed executions that need attention. Observation history is bounded per recurring definition so long query ranges cannot load an unbounded queue history. High-frequency definitions appear once as cadence bands rather than expanding thousands of occurrences; lower-frequency definitions are positioned on a fixed 24-hour week grid. Overlaps share horizontal lanes, and event height uses actual or planned duration, a provider estimate, or a 30-minute fallback. Dashed borders mark estimates, whose provenance appears in expanded details. Expand an event to compare planned and actual timestamps and duration, then follow its link to the owning queue or chat. Labels use the browser's named timezone, shown above the calendar.
