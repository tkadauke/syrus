# Runs one user-submitted `!` shell command against a Coding Mode or Local
# Mode chat session's checkout (see ChatShellCommandExecutor and
# ChatShellCommandsController) -- Coding Mode runs it directly against the
# chat's persistent ChatWorkspace; Local Mode dispatches it over the reverse
# tunnel to the operator's own machine. Joins ChatTurnJob's own per-chat
# concurrency group so a shell command and an agent turn never touch the
# same checkout at once.
class ChatShellCommandJob < ApplicationJob
  queue_as :chat
  discard_on ActiveRecord::RecordNotFound

  # No enforced execution timeout by default (operator-accepted risk,
  # equivalent to already running the Terminal plugin — see EPIC-323). This
  # ceiling only backstops a command that is never cancelled and never exits
  # on its own; it is not meant to fire in normal operation.
  MAX_RUNTIME_SECONDS = 24.hours.to_i

  limits_concurrency to: 1, group: ChatTurnJob::CONCURRENCY_GROUP, key: ->(chat_shell_command_id) {
    "chat:#{ChatShellCommand.where(id: chat_shell_command_id).pick(:chat_session_id)}"
  }, duration: MAX_RUNTIME_SECONDS + 5.minutes

  def perform(chat_shell_command_id)
    @command_record = ChatShellCommand.find(chat_shell_command_id)

    run_command!
  rescue ActiveRecord::RecordNotFound
    # Let `discard_on` (above) handle this directly instead of falling into
    # the blanket rescue below, which would call `finalize!` with
    # `@command_record` still nil (NoMethodError) since the `find` that
    # raised this never completed the assignment.
    raise
  rescue StandardError => e
    Rails.logger.error("[ChatShellCommandJob] chat_shell_command=#{chat_shell_command_id} #{e.class}: #{e.message}")
    finalize!(outcome: "error", output: "[chat_shell_command] #{e.class}: #{e.message}")
  end

  private

  def run_command!
    chat_session = @command_record.chat_session
    executor = ChatShellCommandExecutor::Base.for(chat_session.mode)

    precondition_error = executor.precondition_error(chat_session)
    if precondition_error
      finalize!(outcome: "error", output: precondition_error)
      return
    end

    result = executor.run!(@command_record)
    finalize!(outcome: result.outcome, output: result.output, exit_status: result.exit_status)
  end

  def finalize!(outcome:, output: nil, exit_status: nil)
    @command_record.update!(outcome: outcome, output: output, exit_status: exit_status, finished_at: Time.current)
    post_result_message!
  end

  def post_result_message!
    chat_session = @command_record.chat_session
    message = nil

    ApplicationRecord.transaction do
      chat_session.update!(last_message_at: Time.current)
      message = chat_session.messages.create!(
        role: "user",
        content: {
          "text" => "",
          "chat_shell_command_id" => @command_record.id,
          "internal_prompt" => Prompts::ChatShellCommandResult.new(chat_shell_command: @command_record).to_s
        },
        sender_user_id: @command_record.user_id
      )
    end

    ChatTurnJob.perform_later(chat_session.id, message.id)
  end
end
