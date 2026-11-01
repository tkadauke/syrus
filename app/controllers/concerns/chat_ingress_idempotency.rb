require "digest"

module ChatIngressIdempotency
  extend ActiveSupport::Concern

  included do
    around_action :claim_chat_ingress, only: %i[create message enqueue_message]
  end

  private

  def claim_chat_ingress
    key = params[:client_idempotency_key].to_s
    return yield if key.blank?

    operation = [ action_name, params[:id].presence ].compact.join(":")
    digest = Digest::SHA256.hexdigest(JSON.generate(canonical_ingress_value(params.to_unsafe_h.except("controller", "action", "client_idempotency_key"))))
    replay = nil

    ApplicationRecord.transaction(requires_new: true) do
      receipt = find_or_create_ingress_receipt!(key:, operation:, digest:)
      if receipt.response_status.present?
        replay = receipt
        next
      end

      yield
      raise ChatIngressUnsuccessful unless response.successful?

      body = JSON.parse(response.body.presence || "{}")
      chat_id = body.dig("chat", "id") || params[:id]
      message_id = ChatMessage.where(sender_user: Current.user, client_idempotency_key: key).pick(:id)
      receipt.update!(
        chat_session_id: chat_id,
        chat_message_id: message_id,
        chat_queued_message_id: ChatQueuedMessage.where(chat_session_id: chat_id, client_idempotency_key: key).pick(:id),
        response_status: response.status,
        response_body: body
      )
    end

    render json: replay.response_body, status: replay.response_status if replay
  rescue ChatIngressConflict
    render_error("idempotency_conflict", "The idempotency key was already used for a different chat submission.", status: :conflict)
  rescue ChatIngressUnsuccessful
    # Keep the rendered error response, but roll back the claim and any work
    # performed by the action so the same logical send can be retried.
  end

  def find_or_create_ingress_receipt!(key:, operation:, digest:)
    receipt = ChatIngressReceipt.transaction(requires_new: true) do
      ChatIngressReceipt.create!(sender_user: Current.user, idempotency_key: key, operation: operation, payload_digest: digest)
    end
    receipt
  rescue ActiveRecord::RecordNotUnique
    receipt = ChatIngressReceipt.find_by!(sender_user: Current.user, idempotency_key: key)
    raise ChatIngressConflict unless receipt.operation == operation && receipt.payload_digest == digest

    receipt
  end

  def canonical_ingress_value(value)
    case value
    when Hash, ActionController::Parameters
      value.to_h.sort.to_h.transform_values { |nested| canonical_ingress_value(nested) }
    when Array
      value.map { |nested| canonical_ingress_value(nested) }
    else
      value
    end
  end

  class ChatIngressConflict < StandardError; end
  class ChatIngressUnsuccessful < StandardError; end
end
