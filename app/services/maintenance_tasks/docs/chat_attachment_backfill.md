# Backfill Chat File Attachments

Older chat messages, queued messages, and scratchpad items may contain base64-encoded file bytes inside their JSON. New chat writes store those bytes in Active Storage and keep only a small attachment reference in JSON.

Discovery provides the dry-run count shown as the task's total units. Starting the task processes matching rows in bounded batches and reports completed and total units through the standard maintenance-task progress log. Each stored file is downloaded and its byte size and checksum are verified before the inline data is removed.

The task records its per-table position and can be paused and resumed safely. Re-running it skips references that have already been migrated. Malformed base64 or a failed storage verification leaves the original inline data untouched, records the affected row in the checkpoint and event metadata, and makes the task fail visibly after one retry pass. Fixing the underlying record or storage problem and resuming the failed task retries those rows.
