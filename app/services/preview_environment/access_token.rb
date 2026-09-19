class PreviewEnvironment::AccessToken
  PURPOSE = :preview_environment_access

  TTL = ENV.fetch("SYRUS_PREVIEW_ENVIRONMENT_TOKEN_TTL_HOURS", "24").to_i.hours

  def self.issue(environment)
    verifier.generate({ "preview_environment_id" => environment.id }, expires_in: TTL, purpose: PURPOSE)
  end

  def self.preview_environment_id_for(token)
    return nil if token.blank?

    verifier.verify(token.to_s, purpose: PURPOSE)["preview_environment_id"]
  rescue ActiveSupport::MessageVerifier::InvalidSignature, TypeError
    nil
  end

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
end
