# One-shot cancellable shell command execution against a Coding Mode or
# Local Mode chat session's checkout (EPIC-323) -- see ChatShellCommandExecutor
# for the mode-specific execution/cancellation strategy. API-level only — the
# composer trigger and chat rendering of the output live in Compose.tsx and
# MessageCards.tsx.
module Api
  module V1
    module App
      class ChatShellCommandsController < BaseController
        SUPPORTED_MODES = %w[coding local].freeze

        def create
          chat_session = find_chat_session

          unless SUPPORTED_MODES.include?(chat_session.mode)
            render_error("validation_failed", "Shell commands are only available in Coding Mode or Local Mode chat sessions.", status: :unprocessable_content)
            return
          end

          executor = ChatShellCommandExecutor::Base.for(chat_session.mode)
          unless executor.feature_enabled?
            render_error("feature_disabled", "#{mode_label(chat_session.mode)} is not enabled on this instance.", status: :not_found)
            return
          end

          repository = chat_session.repository
          unless repository
            render_error("not_found", "No repository attached to this chat.", status: :not_found)
            return
          end
          return unless authorize_repository_write!(repository)

          precondition_error = executor.precondition_error(chat_session)
          if precondition_error
            render_error("not_found", precondition_error, status: :not_found)
            return
          end

          command = params[:command].to_s
          if command.strip.blank?
            render_error("validation_failed", "command is required.", status: :unprocessable_content)
            return
          end

          command_record, conflict = create_command_if_idle!(chat_session, command)
          if conflict
            code, message, status = conflict
            render_error(code, message, status: status)
            return
          end

          ChatShellCommandJob.perform_later(command_record.id)

          render json: command_record.as_command_json, status: :created
        end

        def cancel
          chat_session = find_chat_session
          command_record = chat_session.chat_shell_commands.find(params[:id])

          repository = chat_session.repository
          unless repository
            render_error("not_found", "No repository attached to this chat.", status: :not_found)
            return
          end
          return unless authorize_repository_write!(repository)

          unless command_record.running?
            render_error("validation_failed", "This shell command has already finished.", status: :unprocessable_content)
            return
          end

          executor = ChatShellCommandExecutor::Base.for(chat_session.mode)
          unless executor.cancellable?(command_record)
            render_error("not_started", "The command has not started running yet. Try again in a moment.", status: :conflict)
            return
          end

          executor.request_cancel!(command_record, user: Current.user)

          render json: command_record.reload.as_command_json
        end

        private

        def find_chat_session
          Current.user.accessible_chat_sessions.active.find(params[:chat_id])
        end

        def mode_label(mode)
          mode == "local" ? "Local Mode" : "Coding Mode"
        end

        # Atomically (row-locked on chat_session) rejects a second in-flight
        # `!` command and refuses to start one while an agent turn already
        # owns the checkout, then creates the record. Returns
        # [command_record, nil] on success or [nil, render_error_args] on
        # rejection so the caller can render outside the lock.
        def create_command_if_idle!(chat_session, command)
          command_record = nil
          conflict = nil

          chat_session.with_lock do
            if chat_session.shell_command_in_flight?
              conflict = [ "conflict", "A shell command is already running for this chat.", :conflict ]
            elsif chat_session.turn_in_flight? || chat_session.agent_busy?
              conflict = [ "turn_in_flight", "Cannot run a shell command while a turn is in progress.", :conflict ]
            else
              command_record = chat_session.chat_shell_commands.create!(
                user: Current.user,
                command: command,
                started_at: Time.current
              )
            end
          end

          [ command_record, conflict ]
        end
      end
    end
  end
end
