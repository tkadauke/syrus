class ChatCodingRelayRefreshJob < ApplicationJob
  queue_as :chat
  discard_on ActiveRecord::RecordNotFound

  # Distinct coding_checkout_prepare_status value stamped when this job is
  # correctly routed to the worker that recorded the checkout
  # (ChatSession#workspace_storage_key) but the checkout is no longer on that
  # worker's disk — a genuine loss (wiped disk, evicted PVC), not a routing
  # mistake. Never re-clone here: the checkout may hold uncommitted agent
  # work, and a silent re-clone would destroy it.
  WORKSPACE_LOST_STATUS = "workspace_lost".freeze

  def perform(chat_session_id)
    chat_session = ChatSession.find(chat_session_id)
    repository = chat_session.repository
    return unless repository

    path = ChatWorkspace.repo_path_for(chat_session, repository)
    if path.join(".git").directory?
      ChatWorkspace.refresh_relay_credentials!(chat_session, repository)
      return
    end

    record_missing_checkout!(chat_session, path)
  end

  private

  # Only treat this as a definitive loss when we can confirm we are the
  # worker the checkout was recorded on. A blank workspace_storage_key means
  # the checkout (if any) was never attributed to a specific worker — routing
  # fell back to the unaffinitized `chat` queue, so landing here proves
  # nothing about whether the checkout exists elsewhere. A mismatched key
  # means routing put us on the wrong worker; don't misreport that as loss.
  def record_missing_checkout!(chat_session, path)
    expected_key = chat_session.workspace_storage_key
    return if expected_key.blank?

    current_key = WorkerStorageIdentity.key
    if expected_key != current_key
      Rails.logger.warn(
        "[ChatCodingRelayRefreshJob] chat #{chat_session.id} routed to worker #{current_key}, " \
        "but checkout recorded on #{expected_key}; leaving relay credentials untouched"
      )
      return
    end

    message = "Coding checkout for chat #{chat_session.id} is missing on worker #{current_key} " \
              "(expected at #{path}); not re-cloning, needs manual re-attach"
    Rails.logger.error("[ChatCodingRelayRefreshJob] #{message}")

    chat_session.update_columns(
      coding_checkout_prepare_status: WORKSPACE_LOST_STATUS,
      coding_checkout_prepare_failure: message.truncate(2_000),
      coding_checkout_prepare_finished_at: Time.current,
      coding_relay_address: nil,
      coding_relay_token: nil,
      updated_at: Time.current
    )
  end
end
