module ConnectedAccounts
  class PendingFlow < ApplicationRecord
    self.table_name = "connected_accounts_pending_flows"
    belongs_to :owner_user, class_name: "::User"
    attribute :requested_scopes, :json, default: -> { [] }
    encrypts :code_verifier

    scope :live, -> { where(consumed_at: nil).where("expires_at > ?", Time.current) }

    def self.digest(state) = Digest::SHA256.hexdigest(state.to_s)

    def consume!
      with_lock do
        raise OauthFlow::InvalidState, "OAuth state is invalid or expired" if consumed_at? || expires_at <= Time.current
        update!(consumed_at: Time.current)
      end
    end
  end
end
