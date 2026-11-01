module AuthorizationCheckpointOrigin
  extend ActiveSupport::Concern

  included do
    has_many :authorization_requests,
      -> { where(request_kind: "authorization_request") },
      as: :origin,
      class_name: "ChatPendingAction",
      dependent: :nullify
    has_many :authorization_request_occurrences,
      as: :origin,
      class_name: "PendingActionOccurrence",
      dependent: :destroy
    has_many :related_authorization_requests,
      through: :authorization_request_occurrences,
      source: :chat_pending_action
  end

  def waiting_for_permission?
    authorization_requests.waiting_for_permission.exists?
  end
end
