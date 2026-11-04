module Coworkers
  class UnsavedWorkspace
    TURN_ATTEMPTS = 3
    RETRY_CAP = 12
    TURN_BACKOFF = [ 0.25, 0.5 ].freeze
    BACKGROUND_BACKOFF = [ 1.minute, 5.minutes, 15.minutes, 30.minutes ].freeze

    def initialize(chat_session, sleeper: Kernel)
      @chat_session = chat_session
      @link = Coworkers::Chat.find_by!(chat_session_id: chat_session.id)
      @sleeper = sleeper
    end

    def attempt(branch:, path:, schedule_background: true)
      failures = 0
      first_failure_at = nil
      begin
        yield
        clear!
        :saved
      rescue GitRunner::GitError => error
        failure = Coworkers::PushFailure.for(error)
        failures += 1
        first_failure_at ||= Time.current
        if failure.transient? && failures < TURN_ATTEMPTS && @link.unsaved_workspace_attempt_count.to_i + failures < RETRY_CAP
          @sleeper.sleep(TURN_BACKOFF.fetch(failures - 1))
          retry
        end
        record!(failure, branch:, path:, attempts: failures, first_failure_at:)
        schedule_retry! if failure.transient? && schedule_background
        :unsaved
      end
    end

    def schedule_retry!
      @link.with_lock do
        return if @link.unsaved_workspace_retry_exhausted_at?
        return if @link.unsaved_workspace_retry_scheduled_at?
        if @link.unsaved_workspace_attempt_count.to_i >= RETRY_CAP
          @link.update!(unsaved_workspace_retry_exhausted_at: Time.current)
          update_notice!
          return
        end

        delay = BACKGROUND_BACKOFF.fetch([ @link.unsaved_workspace_attempt_count.to_i / TURN_ATTEMPTS, BACKGROUND_BACKOFF.length - 1 ].min)
        @link.update!(unsaved_workspace_retry_scheduled_at: Time.current)
        Coworkers::WorkspaceSaveRetryJob.set(wait: delay).perform_later(@link.id)
      end
    end

    def begin_retry!
      @link.update!(unsaved_workspace_retry_scheduled_at: nil)
    end

    private

    def record!(failure, branch:, path:, attempts:, first_failure_at:)
      now = Time.current
      @link.with_lock do
        @link.update!(
          unsaved_workspace_branch: branch,
          unsaved_workspace_path: path.to_s,
          unsaved_workspace_error: failure.error.message,
          unsaved_workspace_failure_kind: failure.kind,
          unsaved_workspace_first_failed_at: @link.unsaved_workspace_first_failed_at || first_failure_at,
          unsaved_workspace_last_failed_at: now,
          unsaved_workspace_attempt_count: @link.unsaved_workspace_attempt_count.to_i + attempts
        )
        update_notice!
      end
    end

    def update_notice!
      message = @link.unsaved_workspace_notice_message_id && @chat_session.messages.find_by(id: @link.unsaved_workspace_notice_message_id)
      content = notice_content
      if message
        message.update!(content: content)
        message.send(:broadcast_app_event)
      else
        message = @chat_session.messages.create!(role: "system", content:, skip_turn_trigger: true)
        @link.update_column(:unsaved_workspace_notice_message_id, message.id)
      end
    end

    def clear!
      return unless @link.reload.unsaved_workspace_branch?

      @link.update!(
        unsaved_workspace_branch: nil, unsaved_workspace_path: nil, unsaved_workspace_error: nil,
        unsaved_workspace_failure_kind: nil, unsaved_workspace_first_failed_at: nil,
        unsaved_workspace_last_failed_at: nil, unsaved_workspace_attempt_count: nil,
        unsaved_workspace_notice_message_id: nil, unsaved_workspace_retry_exhausted_at: nil,
        unsaved_workspace_retry_scheduled_at: nil
      )
      @chat_session.messages.create!(
        role: "system", skip_turn_trigger: true,
        content: { "text" => I18n.t("api.coworkers.workspace_save_resolved"),
                   "prominent" => true, "system_label" => I18n.t("api.coworkers.workspace_save_resolved_label"), "system_tone" => "success",
                   "coworker_workspace_save_resolved" => true }
      )
    end

    def notice_content
      exhausted = @link.unsaved_workspace_retry_exhausted_at?
      {
        "text" => I18n.t("api.coworkers.unsaved_workspace", path: @link.unsaved_workspace_path,
          retry_status: I18n.t(exhausted ? "api.coworkers.retry_stopped" : "api.coworkers.retry_pending"),
          error: @link.unsaved_workspace_error),
        "body_format" => "markdown", "prominent" => true,
        "system_label" => I18n.t("api.coworkers.unsaved_workspace_label"), "system_tone" => "warning",
        "system_cta" => { "label" => I18n.t("api.coworkers.unsaved_workspace_cta"), "path" => "/coworkers/#{@link.coworker_id}?tab=workspace" },
        "coworker_unsaved_workspace" => { "branch" => @link.unsaved_workspace_branch, "path" => @link.unsaved_workspace_path,
          "failure_kind" => @link.unsaved_workspace_failure_kind, "attempt_count" => @link.unsaved_workspace_attempt_count,
          "first_failed_at" => @link.unsaved_workspace_first_failed_at&.iso8601,
          "last_failed_at" => @link.unsaved_workspace_last_failed_at&.iso8601, "retry_exhausted" => exhausted }
      }
    end
  end
end
