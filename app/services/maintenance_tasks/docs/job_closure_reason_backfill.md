# Job closure reason backfill

Normalizes legacy closed Jobs in bounded primary-key windows. The task is idempotent: it maps old approval/no-change values, fills infrastructure closures, and recovers duplicate or explicitly recorded cancellation reasons where durable evidence exists. Ambiguous human cancellations remain `cancelled`.
