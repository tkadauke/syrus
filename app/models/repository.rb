class Repository < ApplicationRecord
  include AutoApproveModes

  GITHUB_NAME = /\A[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?\z/
  REVIEW_POLICIES = %w[ self two_person final_say ].freeze
  FEEDBACK_POLICIES = %w[ auto confirm ].freeze
  HEALTH_STATES = %w[ unknown healthy broken ].freeze

  attribute :polling_enabled, :boolean, default: true
  attribute :prepare_enabled, :boolean, default: true
  attribute :pr_cost_footer_enabled, :boolean, default: true
  attribute :auto_merge_enabled, :boolean, default: false
  attribute :approval_propagates_to_github, :boolean, default: true
  # Opt-in: reuse a PR's green grade across a clean (conflict-free)
  # rebase instead of re-running the landing graders. Trades a small
  # logical-conflict risk for landing throughput. See Steps::ForcePush.
  attribute :trust_clean_rebase_grade, :boolean, default: false
  attribute :feedback_policy, :string, default: "confirm"
  attribute :fork_pr_grace_period_hours, :integer, default: 24
  attribute :upstream_pr_grace_period_days, :integer, default: 7
  attribute :ci_health, :string, default: "unknown"
  attribute :grader_health, :string, default: "unknown"
  attribute :landing_paused, :boolean, default: false

  enum :ci_health, HEALTH_STATES.index_with(&:itself), prefix: true, validate: true
  enum :grader_health, HEALTH_STATES.index_with(&:itself), prefix: true, validate: true

  belongs_to :user, optional: true
  belongs_to :installation, optional: true
  belongs_to :upstream_repository, class_name: "Repository", optional: true, inverse_of: :fork_repositories
  has_many :fork_repositories, class_name: "Repository", foreign_key: :upstream_repository_id, dependent: :nullify, inverse_of: :upstream_repository
  has_many :repository_memberships, dependent: :destroy
  has_many :members, through: :repository_memberships, source: :user
  has_many :repository_final_approvers, dependent: :destroy
  has_many :final_approvers, through: :repository_final_approvers, source: :user
  has_many :jobs, dependent: :destroy
  has_many :epics, dependent: :destroy
  has_many :scheduled_tasks, dependent: :destroy
  has_many :chat_attachments, as: :attachable, dependent: :destroy
  has_many :chat_sessions, through: :chat_attachments
  has_many :documents, as: :attachable, dependent: :destroy
  has_many :repository_documents, as: :attachable, class_name: "Document", dependent: :destroy
  has_many :chat_pending_actions, dependent: :destroy

  validates :owner, presence: true, format: { with: GITHUB_NAME }
  validates :name, presence: true, format: { with: GITHUB_NAME }
  validates :upstream_owner, format: { with: GITHUB_NAME }, allow_blank: true
  validates :upstream_name, format: { with: GITHUB_NAME }, allow_blank: true
  validates :default_branch, presence: true
  validates :trigger_label, presence: true
  validates :agent_provider, inclusion: { in: User::AGENT_PROVIDERS }, allow_nil: true
  validates :review_policy, presence: true, inclusion: { in: REVIEW_POLICIES }
  validates :feedback_policy, presence: true, inclusion: { in: FEEDBACK_POLICIES }
  validates :name, uniqueness: {
    scope: :owner,
    case_sensitive: false,
    message: "has already been registered for this GitHub owner"
  }
  validate :upstream_owner_and_name_are_paired

  before_validation :normalize_agent_provider
  before_validation :normalize_upstream_metadata
  before_save :link_installation_from_owner
  after_create :seed_owner_membership
  before_destroy :destroy_chat_sessions, prepend: true

  scope :active,   -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  def archived?
    archived_at.present?
  end

  def main_health
    return "broken" if ci_health_broken? || grader_health_broken?
    return "healthy" if ci_health_healthy? && grader_health_healthy?
    "unknown"
  end

  def main_health_broken?
    main_health == "broken"
  end

  def main_health_unknown?
    main_health == "unknown"
  end

  def feedback_policy_auto?
    feedback_policy == "auto"
  end

  def feedback_policy_confirm?
    feedback_policy == "confirm"
  end

  # Mark the repo as done. Side-effect: also flips polling_enabled off so
  # that *if* someone unarchives later, polling stays off until they
  # explicitly re-enable it (re-enabling polling is a deliberate act, not
  # something that should silently rehydrate from a stale flag).
  def archive!
    update!(archived_at: Time.current, polling_enabled: false)
  end

  def unarchive!
    update!(archived_at: nil)
  end

  def slug
    "#{owner}/#{name}"
  end

  def upstream_slug
    return nil if upstream_owner.blank? || upstream_name.blank?

    "#{upstream_owner}/#{upstream_name}"
  end

  def effective_agent_provider(user: nil)
    if user
      membership_provider = repository_memberships.find_by(user_id: user.id)&.agent_provider&.presence
      return membership_provider if membership_provider
    end
    agent_provider.presence || (user || self.user)&.agent_provider
  end

  def effective_prepare_enabled
    prepare_enabled?
  end

  def app_credential_active?
    AppSetting.github_app_registered? && installation&.active?
  end

  def credential_mode
    app_credential_active? ? "app" : "pat"
  end

  # Anonymous URL — safe to bake into a saved clone's remote.
  def remote_url
    "https://github.com/#{owner}/#{name}.git"
  end

  # Token-bearing URL used for push only. Constructed per-call so the token
  # never lives on disk inside .git/config.
  def authenticated_push_url(token)
    "https://x-access-token:#{token}@github.com/#{owner}/#{name}.git"
  end

  private

  def normalize_agent_provider
    self.agent_provider = nil if agent_provider.blank?
  end

  def normalize_upstream_metadata
    self.upstream_owner = upstream_owner.presence
    self.upstream_name = upstream_name.presence
    self.upstream_default_branch = upstream_default_branch.presence
  end

  def upstream_owner_and_name_are_paired
    return if upstream_owner.blank? && upstream_name.blank?
    return if upstream_owner.present? && upstream_name.present?

    errors.add(:upstream_owner, "and upstream name must both be present")
  end

  def link_installation_from_owner
    return unless will_save_change_to_owner? || installation_id.blank?
    self.installation = InstallationLinker.find_for_owner(owner)
  end

  def destroy_chat_sessions
    chat_sessions.find_each(&:destroy)
  end

  def seed_owner_membership
    return unless user_id.present?
    repository_memberships.find_or_create_by!(user_id: user_id) { |m| m.role = "owner" }
  end
end
