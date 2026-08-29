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
    TEXT
  end
end
