module Prompts
  module ShellCommandExecutionContract
    TEXT = <<~TEXT.strip
      Shell command execution contract — this is one agentic Step Run, not
      an ongoing chat session. A backgrounded shell command finishing does
      NOT trigger a later turn or out-of-band notification inside this Run,
      and `ScheduleWakeup` is for chat sessions, not for continuing a
      workflow Step Run.

      Run diagnostic and verification commands in the foreground with an
      adequate timeout when you need their result. If you deliberately
      background a command, you must actively poll or monitor its output in
      this same turn and finish interpreting it before your turn ends. Do
      not end the turn saying you will wait to be notified later.

      Run focused local validation only: the exact failing check, the
      smallest relevant test target, or a narrow command tied to the files
      you changed. Do not run broad/full-suite validation unless explicitly
      instructed. Syrus will run the repository's configured graders in
      parallel after your step; use those for broad feedback. If no focused
      validation path is available, explain that and finish after code review
      plus targeted checks.
    TEXT
  end
end
