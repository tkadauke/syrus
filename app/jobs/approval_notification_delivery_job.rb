class ApprovalNotificationDeliveryJob < ApplicationJob
  queue_as :control_plane

  BATCH_LIMIT = 20

  def perform(request_id)
    anchor = ChatPendingAction.find_by(id: request_id, request_kind: "authorization_request")
    return unless anchor&.delivery_state == "queued" && anchor.pending?

    requests = claim_due_requests(anchor.user)
    return if requests.empty?

    notification = NotificationService.create_for(
      user: anchor.user,
      kind: "approval_request",
      body: notification_body(requests),
      target_path: "/permissions/inbox",
      dedupe_key: "approval-requests:#{requests.map(&:id).sort.join('-')}"
    )
    requests.each do |request|
      request.record_delivery!(metadata: { "notification_id" => notification&.id, "batch_size" => requests.size })
    end
  rescue => error
    Array(@claimed_requests).each { |request| request.record_delivery_failure!(error, metadata: { "channel" => "external" }) }
    raise
  end

  private

  def due_requests(user)
    ChatPendingAction.where(user:, request_kind: "authorization_request", state: "pending", delivery_state: "queued").order(:created_at).select do |request|
      Time.iso8601(request.delivery_metadata.fetch("deliver_after")) <= Time.current
    rescue KeyError, ArgumentError
      true
    end
  end

  def claim_due_requests(user)
    ChatPendingAction.transaction do
      candidates = due_requests(user).first(BATCH_LIMIT)
      @claimed_requests = ChatPendingAction.lock.where(id: candidates.map(&:id), delivery_state: "queued", state: "pending").order(:created_at).to_a
      ChatPendingAction.where(id: @claimed_requests.map(&:id)).update_all(delivery_state: "delivering", updated_at: Time.current)
      @claimed_requests.each { |request| request.delivery_state = "delivering" }
    end
    @claimed_requests
  end

  def notification_body(requests)
    if requests.one?
      I18n.t("notifications.approval_request.one", purpose: requests.first.purpose.presence || I18n.t("notifications.approval_request.fallback"))
    else
      I18n.t("notifications.approval_request.other", count: requests.size)
    end
  end
end
