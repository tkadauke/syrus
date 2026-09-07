module ChatShellCommandExecutor
  # Coding Mode `!` commands run directly on the worker against the chat
  # session's persistent ChatWorkspace checkout via ProcessRunner.
  class Coding < Base
    def feature_enabled?
      Feature.coding_mode_enabled?
    end

    def precondition_error(chat_session)
      return "No repository attached to this chat." unless chat_session.repository
      return "No active coding checkout for this chat." if chat_session.coding_checkout_branch.blank?

      nil
    end

    def run!(command_record)
      chat_session = command_record.chat_session
      repository = chat_session.repository
      path = ChatWorkspace.repo_path_for(chat_session, repository)
      return Result.new(outcome: "error", output: "Coding checkout not found at #{path}.") unless path.join(".git").directory?

      output = +""
      env = ProcessRunner.forwarded_env(ChatWorkspacePrepareJob::PREP_ENV_FORWARD)
      result = ProcessRunner.new(
        env: env,
        command: [ "bash", "-c", command_record.command ],
        chdir: path,
        timeout: ChatShellCommandJob::MAX_RUNTIME_SECONDS,
        kind: "chat_shell_command",
        chat_session: chat_session,
        on_output_chunk: ->(chunk) { output = ChatShellCommand.append_capped(output, chunk) },
        on_spawned_process: ->(spawned_process) { command_record.update_columns(spawned_process_id: spawned_process.id) }
      ).run

      Result.new(outcome: outcome_for(result), output: output, exit_status: result.exit_status)
    end

    def cancellable?(command_record)
      command_record.spawned_process.present? && command_record.spawned_process.running?
    end

    def request_cancel!(command_record, user:)
      command_record.spawned_process.request_kill!(user: user)
    end

    private

    def outcome_for(result)
      return "killed" if result.operator_killed?
      return "succeeded" if result.success?

      "failed"
    end
  end
end
