# Backfill Agent Records

Syrus now has a first-class `Agent` model that groups the runtime activity for a Run, Chat session, or Design Docs agent run. New activity creates these rows automatically, but older records may predate the table or the `spawned_processes.agent_id` link.

This maintenance task creates the missing historical Agent rows and links historical spawned processes to the Agent for their owning Run or Chat session. It does not change workflow state, retry work, edit repositories, call GitHub, or invoke an AI provider.

The task is chunked and resumable. It is safe to pause while running; resuming continues with whichever historical rows are still missing attribution. If there are no historical records left to backfill, Syrus hides the task automatically.
