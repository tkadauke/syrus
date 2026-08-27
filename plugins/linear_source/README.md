# Linear Source

Linear Source connects Syrus to Linear teams and issues. It lets operators ingest Linear work into Syrus jobs and epics while preserving Linear as the planning system of record.

The plugin is disabled by default because it requires Linear credentials and team selection. It complements GitHub Source: Linear can provide the work intake while GitHub remains the code and PR backend.

## What It Adds

- Linear team lookup and configuration endpoints.
- A Linear input source for creating Syrus jobs from Linear issues.
- Metadata linking Syrus work back to the originating Linear item.

## When To Enable

Enable Linear Source when a team plans work in Linear and wants Syrus to implement against GitHub repositories from that queue.

## Operational Notes

Linear ingestion should be configured per team or project so Syrus only imports work that belongs in the automation flow.
