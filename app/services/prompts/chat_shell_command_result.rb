module Prompts
  # The agent-facing text for a completed `!` shell command (EPIC-323). The
  # chat message itself carries an empty display "text" — the composer
  # renders the command + output as a dedicated monospace/ANSI card
  # (MessageCards.tsx ShellCommandCard) instead of chat prose — so this is
  # stored as the message's "internal_prompt" (see ChatTurnJob#prompt_text_for_agent)
  # to give the agent something to actually read for this turn.
  class ChatShellCommandResult
    def initialize(chat_shell_command:)
      @chat_shell_command = chat_shell_command
    end

    def to_s
      <<~TEXT.strip
        The operator ran a `!` shell command directly in this chat's checkout:

        $ #{@chat_shell_command.command}

        #{output}

        (#{outcome_label}#{exit_status_suffix})
      TEXT
    end

    private

    def output
      @chat_shell_command.output.presence || "(no output)"
    end

    def outcome_label
      case @chat_shell_command.outcome
      when "succeeded" then "succeeded"
      when "failed" then "failed"
      when "killed" then "cancelled by the operator before it finished"
      when "error" then "could not run"
      else "outcome unknown"
      end
    end

    def exit_status_suffix
      return "" unless @chat_shell_command.exit_status

      ", exit #{@chat_shell_command.exit_status}"
    end
  end
end
