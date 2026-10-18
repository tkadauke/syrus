# Process execution

Production Ruby code runs external commands through `ProcessRunner`. This
keeps environment scrubbing, workspace and Job attribution, execution mounts
and network profiles, process-group cleanup, operator cancellation,
heartbeats, command redaction, resource accounting, and final outcomes in one
lifecycle implementation.

Choose the API that matches the command:

- Use `ProcessRunner#capture` for a short command whose bounded stdout and
  stderr must be returned separately. It accepts `stdin_data:` through the
  normal constructor and reports independently truncated streams.
- Use `ProcessRunner#run` for a foreground command whose output should be
  consumed incrementally through `on_output_chunk:` or `on_output_line:`.
  Wall timeout, silent timeout, cancellation, and process-group cleanup remain
  active while output is streamed.
- Use `ProcessRunner.pipeline(commands: ...)` for connected commands. Every
  command is a separately registered child with its own outcome; a failed or
  missing command does not leave the other children unaccounted for.
- Use `ProcessRunner#start` for a service that must continue after launch. It
  requires a `kind:` and returns a `BackgroundHandle` keyed by the durable
  `SpawnedProcess` row. Call `finalize` to join an in-process handle or recover
  a completed result with `BackgroundHandle.find(id).finalize`; call `cancel!`
  to use the same operator-cancellation path as foreground work.

All modes require explicit `mounts:` and `network:` declarations. Production
callers also pass a registered `kind:` plus the available Run, Workflow, Job,
chat session, or agent attribution. Use `display_command:` when the executable
arguments contain credentials or other values that should not be persisted;
stored commands are additionally passed through `CommandRedactor`.
