module AuthorizationCheckpointOrigin
  extend ActiveSupport::Concern

  included do
    has_many :authorization_requests,
      -> { where(request_kind: "authorization_request") },
      as: :origin,
      class_name: "ChatPendingAction",
      dependent: :nullify
  end

  def waiting_for_permission?
    authorization_requests.waiting_for_permission.exists?
  end
end
