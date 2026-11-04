class Coworkers::UnsavedWorkspace
  IN_TURN_ATTEMPTS = 3
  RETRY_CAP = 12
  BACKOFF = [ 0.25, 1 ].freeze
  BACKGROUND_DELAY = 1.minute

  def initialize(chat, sleeper: Kernel)
    @chat = chat
    @link = Coworkers::Chat.find_by!(chat_session_id: chat.id)
    @sleeper = sleeper
  end

  def attempt(branch:, path:, operation:, schedule_background: true)
    remaining = [ IN_TURN_ATTEMPTS, RETRY_CAP - @link.unsaved_workspace_attempt_count.to_i ].min
    remaining = 1 if remaining < 1

    remaining.times do |index|
      outcome = yield
      return outcome if outcome == :conflict

      clear! if @link.reload.unsaved_workspace?
      return outcome
    rescue GitRunner::GitError => error
      failure = Coworkers::PushFailure.for(error)
      record!(branch:, path:, operation:, failure:)
      break unless failure.transient? && index < remaining - 1 && !exhausted?

      @sleeper.sleep(BACKOFF.fetch(index, BACKOFF.last))
    end

    schedule_retry! if schedule_background && transient? && !exhausted?
    :unsaved
  end

  def schedule_manual_retry!
    schedule_retry!(delay: 0.seconds, replace: true)
  end

  def begin_retry!(token)
    @link.with_lock do
      @link.reload
      return false unless @link.unsaved_workspace? && ActiveSupport::SecurityUtils.secure_compare(@link.unsaved_workspace_retry_token.to_s, token.to_s)

      @link.update!(unsaved_workspace_retry_scheduled_at: nil)
      true
    end
  end

  private

  def record!(branch:, path:, operation:, failure:)
    now = Time.current
    @link.with_lock do
      @link.reload
      attempts = @link.unsaved_workspace_attempt_count.to_i + 1
      @link.update!(
        unsaved_workspace_branch: branch, unsaved_workspace_path: path.to_s,
        unsaved_workspace_error: failure.error.message.last(2_000), unsaved_workspace_failure_kind: failure.kind,
        unsaved_workspace_operation: operation, unsaved_workspace_first_failed_at: @link.unsaved_workspace_first_failed_at || now,
        unsaved_workspace_last_failed_at: now, unsaved_workspace_attempt_count: attempts,
        unsaved_workspace_retry_exhausted_at: attempts >= RETRY_CAP ? now : nil
      )
      upsert_notice!
    end
  end

  def schedule_retry!(delay: BACKGROUND_DELAY, replace: false)
    token = SecureRandom.uuid
    scheduled = false
    @link.with_lock do
      @link.reload
      return if @link.unsaved_workspace_retry_scheduled_at.present? && !replace

      @link.update!(unsaved_workspace_retry_scheduled_at: Time.current, unsaved_workspace_retry_token: token)
      scheduled = true
    end
    Coworkers::WorkspaceSaveRetryJob.set(wait: delay).perform_later(@link.id, token) if scheduled
  end

  def clear!
    notice_was_present = @link.unsaved_workspace_notice_message_id.present?
    @link.update!(clear_attributes)
    return unless notice_was_present

    @chat.messages.create!(role: "system", content: {
      "text" => I18n.t("api.coworkers.workspace_save_resolved"), "system_tone" => "success",
      "system_label" => I18n.t("api.coworkers.workspace_save_label"), "coworker_workspace_save_resolved" => true
    })
  end

  def clear_attributes
    Coworkers::Chat.column_names.grep(/\Aunsaved_workspace_/).index_with(nil).merge("unsaved_workspace_attempt_count" => 0)
  end

  def upsert_notice!
    content = notice_content
    message = @chat.messages.find_by(id: @link.unsaved_workspace_notice_message_id)
    if message
      message.update!(content: content)
    else
      message = @chat.messages.create!(role: "system", content: content)
      @link.update_column(:unsaved_workspace_notice_message_id, message.id)
    end
  end

  def notice_content
    status_key = if @link.unsaved_workspace_failure_kind == "permanent"
      "needs_attention"
    elsif exhausted?
      "retry_exhausted"
    else
      "retry_pending"
    end
    {
      "text" => I18n.t("api.coworkers.workspace_save_failed", branch: @link.unsaved_workspace_branch,
        attempts: @link.unsaved_workspace_attempt_count, status: I18n.t("api.coworkers.#{status_key}")),
      "system_tone" => "warning", "system_label" => I18n.t("api.coworkers.workspace_save_label"),
      "prominent" => true, "coworker_unsaved_workspace" => @link.unsaved_workspace_json,
      "system_cta" => { "label" => I18n.t("api.coworkers.retry_save"), "path" => "/coworkers/#{@link.coworker_id}?tab=workspace" }
    }
  end

  def exhausted? = @link.unsaved_workspace_attempt_count.to_i >= RETRY_CAP
  def transient? = @link.unsaved_workspace_failure_kind == "transient"
end
