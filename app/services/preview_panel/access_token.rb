# Short-lived signed token (panel id + expiry) that authorizes cross-origin
# access to a private PreviewPanel. Stateless (ActiveSupport::MessageVerifier)
# rather than a DB-backed token: the panel id is the only claim, and
# MessageVerifier's own expires_in enforces the TTL, so there is nothing to
# revoke or prune. PreviewProxyMiddleware verifies the same token whether it
# arrives as the iframe's `?token=` query param or as the follow-up cookie
# (see #config/syrus_docs/preview_panels.md).
class PreviewPanel::AccessToken
  PURPOSE = :preview_panel_access

  TTL = ENV.fetch("SYRUS_PREVIEW_PANEL_TOKEN_TTL_HOURS", "24").to_i.hours

  def self.issue(panel)
    verifier.generate({ "panel_id" => panel.id }, expires_in: TTL, purpose: PURPOSE)
  end

  def self.panel_id_for(token)
    return nil if token.blank?

    verifier.verify(token, purpose: PURPOSE)["panel_id"]
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end
end
