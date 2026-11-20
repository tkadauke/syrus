require "digest"

# A revocable credential an external MCP client (Claude Code on an
# operator's laptop, say) presents to /mcp/bridge. It is separate from the
# user's API token: it reaches only the chat MCP tools, every call goes
# through the same permission gate, audit and usage recording as an in-app
# chat, and revoking it cuts off that one client.
#
# Only a digest is stored. The plaintext is returned once, at issue time.
# Each token owns one bridge chat, created on first use: that is where the
# client's confirmation cards and authorization requests appear for the
# operator to decide, and what its tool calls are attributed to.
class McpBridgeToken < ApplicationRecord
  TOKEN_PREFIX = "syrus_mcp_".freeze

  belongs_to :user
  belongs_to :chat_session, optional: true

  validates :name, presence: true, length: { maximum: 100 }
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true

  scope :active, -> { where(revoked_at: nil) }

  class << self
    # Returns [token, plaintext]. The plaintext is not recoverable later.
    def issue!(user:, name:)
      plaintext = TOKEN_PREFIX + SecureRandom.urlsafe_base64(32)
      token = create!(user:, name:, token_digest: digest(plaintext), token_prefix: plaintext.first(TOKEN_PREFIX.length + 6))
      [ token, plaintext ]
    end

    def authenticate(plaintext)
      return if plaintext.blank? || !plaintext.start_with?(TOKEN_PREFIX)

      active.includes(:user).find_by(token_digest: digest(plaintext))
    end

    def digest(plaintext) = Digest::SHA256.hexdigest(plaintext.to_s)
  end

  def active? = revoked_at.nil?

  def revoke!
    update!(revoked_at: Time.current) if active?
  end

  def touch_last_used!
    return if last_used_at && last_used_at > 1.minute.ago

    update_columns(last_used_at: Time.current, updated_at: Time.current)
  end

  # The chat this client acts in. Created lazily so an unused token leaves
  # no empty chat behind, and recreated if the operator deleted it.
  def bridge_chat!
    with_lock do
      current = chat_session
      return current if current && !current.deleted?

      created = ChatSession.create!(
        user: user,
        title: I18n.t("mcp_bridge.chat_title", name: name, locale: user.locale.presence || I18n.default_locale),
        origin_platform: ChatSession::MCP_BRIDGE_PLATFORM,
        trigger_policy: "speak_when_spoken_to"
      )
      update!(chat_session: created)
      created
    end
  end

  def as_payload
    {
      id: id,
      name: name,
      token_prefix: token_prefix,
      chat_id: chat_session_id,
      last_used_at: last_used_at&.iso8601,
      revoked_at: revoked_at&.iso8601,
      created_at: created_at&.iso8601
    }
  end
end
