class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :repositories, dependent: :destroy
  has_many :jobs, dependent: :destroy
  has_many :invitations, foreign_key: :invited_by_id, dependent: :nullify
  has_one :github_installation, dependent: :destroy

  encrypts :claude_oauth_token
  encrypts :github_token

  normalizes :email_address, with: ->(e) { e.strip.downcase }

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

  before_create :promote_first_user_to_admin

  def admin?
    admin
  end

  private

  def promote_first_user_to_admin
    self.admin = true if User.count.zero?
  end
end
