module ConnectedAccounts
  module TokenManager
    module_function

    def refresh(account:, tokens:)
      resolved = ResolvedProvider.fetch(account.provider)
      replacement = resolved.call("refresh", Provider::RefreshContext.new(tokens: tokens)).stringify_keys
      replacement["refresh_token"] ||= tokens["refresh_token"]
      expires_at = OauthFlow.normalize_expiry!(replacement)
      account.update!(token_expires_at: expires_at, status: "connected")
      replacement
    end

    def mark_reauth!(account)
      account.update!(status: "needs_reauth", health_message: "Refresh failed")
      Notification.create!(user: account.owner_user, kind: "approval_request",
        body: "A connected account needs to be reauthorized.", target_path: "/settings/connected_accounts",
        dedupe_key: "connected-account-reauth-#{account.id}") unless Notification.exists?(dedupe_key: "connected-account-reauth-#{account.id}")
    end
  end
end
