class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :repositories, dependent: :destroy
  has_many :installations, dependent: :destroy
  has_many :jobs, dependent: :destroy
  has_many :job_pins, dependent: :destroy
  has_many :pinned_jobs, through: :job_pins, source: :job
  has_many :chat_sessions
  has_many :repository_documents, dependent: :destroy
  has_many :chat_pending_actions, dependent: :destroy
  has_many :recurring_tasks, dependent: :destroy
  has_many :cron_templates, dependent: :destroy
  has_many :invitations, foreign_key: :invited_by_id, dependent: :nullify

  AGENT_PROVIDERS = %w[ claude codex ].freeze
  CODEX_AUTH_MODES = %w[ api_key chatgpt_login ].freeze

  encrypts :claude_oauth_token
  encrypts :codex_api_key
  encrypts :codex_auth_json
  encrypts :github_token
  encrypts :telegram_chat_id
  # `deterministic: true` so we can WHERE on the encrypted column
  # for the API auth lookup. Same plaintext always encrypts to the
  # same ciphertext under deterministic mode.
  encrypts :api_token, deterministic: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :github_handle, with: ->(h) { h.to_s.delete_prefix("@").strip.presence }
  normalizes :telegram_chat_id, with: ->(id) { id.to_s.strip.presence }

  # Per-user ceiling on `claude --max-turns`. The agent is given this
  # many tool-use turns before the run terminates with
  # error_max_turns. The previous global default of 50 was too low for
  # non-trivial issues — operators saw runs hit the cap mid-task. 200
  # covers the long tail; runaway loops still terminate eventually.
  #
  # Special-case: 0 means "no cap" (don't pass `--max-turns` at all).
  # AgentInvocation::DEFAULT_TIMEOUT_SECONDS still bounds the run, so a
  # genuinely-stuck agent doesn't run forever even with no turn cap.
  AGENT_MAX_TURNS_RANGE = (0..1000)

  validates :agent_max_turns,
            presence: true,
            numericality: { only_integer: true, in: AGENT_MAX_TURNS_RANGE }
  validates :agent_provider, presence: true, inclusion: { in: AGENT_PROVIDERS }
  validates :codex_auth_mode, presence: true, inclusion: { in: CODEX_AUTH_MODES }
  validates :telegram_chat_id,
            format: { with: /\A-?\d+\z/, message: "must be a numeric Telegram chat id" },
            allow_blank: true

  before_create :promote_first_user_to_admin

  def admin?
    admin
  end

  def display_name
    name.presence || email_address
  end

  def configured_agent_providers
    AGENT_PROVIDERS.select { |provider| agent_provider_configured?(provider) }
  end

  def alternate_configured_agent_providers
    configured_agent_providers - [ agent_provider ]
  end

  def agent_provider_configured?(provider)
    case provider.to_s
    when "claude"
      claude_oauth_token.present?
    when "codex"
      codex_configured?
    else
      false
    end
  end

  # Generate (and persist) a fresh API token. Returns the
  # plaintext token so the caller can show it to the operator
  # ONCE — it's stored deterministic-encrypted, so the operator
  # who doesn't write it down has to rotate. Crypt-quality random:
  # 32 bytes of urlsafe base64 (~43 chars).
  API_TOKEN_PREFIX = "syrus_".freeze

  def generate_api_token!
    token = API_TOKEN_PREFIX + SecureRandom.urlsafe_base64(32)
    update!(api_token: token)
    token
  end

  def revoke_api_token!
    update!(api_token: nil)
  end

  # Toggle for the dashboard banner. Set when a GitHub API call
  # returns a permission-class error (403 "Resource not accessible
  # by personal access token", 401, etc.) — so the operator sees a
  # banner pointing at /credentials and polling jobs know to
  # degrade specific endpoints rather than crash. `reason` is the
  # short error string verbatim from Octokit, displayed in the
  # banner so the operator can match against GH docs.
  def mark_gh_api_blocked!(reason)
    return if gh_api_blocked_at && gh_api_blocked_reason == reason  # idempotent — don't bump timestamps for the same recurring error
    update_columns(gh_api_blocked_at: Time.current, gh_api_blocked_reason: reason.to_s[0, 500])
  end

  def clear_gh_api_blocked!
    return unless gh_api_blocked_at
    update_columns(gh_api_blocked_at: nil, gh_api_blocked_reason: nil)
  end

  def gh_api_blocked?
    gh_api_blocked_at.present?
  end

  private

  def codex_configured?
    case codex_auth_mode
    when "api_key"
      codex_api_key.present?
    when "chatgpt_login"
      codex_auth_json.present?
    else
      false
    end
  end

  def promote_first_user_to_admin
    self.admin = true if User.count.zero?
  end
end
