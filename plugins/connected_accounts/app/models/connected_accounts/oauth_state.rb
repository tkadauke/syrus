module ConnectedAccounts
  class OauthState < ApplicationRecord
    self.table_name = "connected_accounts_oauth_states"
    TTL = 10.minutes
    belongs_to :user, class_name: "::User"
    encrypts :code_verifier
    attribute :requested_scopes, :json, default: -> { [] }

    def self.issue!(user:, session_binding:, provider:, requested_scopes:, read_only:)
      token = SecureRandom.urlsafe_base64(32)
      verifier = SecureRandom.urlsafe_base64(64)
      create!(digest: digest(token), session_digest: digest(session_binding), code_verifier: verifier,
        user: user, provider: provider, requested_scopes: requested_scopes, read_only: read_only, expires_at: TTL.from_now)
      [ token, verifier ]
    end

    def self.consume!(token:, user:, session_binding:, provider:)
      transaction do
        state = lock.find_by!(digest: digest(token))
        valid = state.user_id == user.id && state.session_digest == digest(session_binding) && state.provider == provider && state.used_at.nil? && state.expires_at.future?
        raise ActiveRecord::RecordNotFound unless valid
        state.update!(used_at: Time.current)
        state
      end
    end

    def self.digest(value) = Digest::SHA256.hexdigest(value.to_s)
  end
end
