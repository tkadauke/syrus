class Repository < ApplicationRecord
  include AutoApproveModes

  GITHUB_NAME = /\A[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?\z/
  REVIEW_POLICIES = %w[ self two_person final_say ].freeze
  FEEDBACK_POLICIES = %w[ auto confirm ].freeze
  EPIC_DEPENDENCY_POLICIES = %w[ linear nonlinear ].freeze
  CI_HEALTH_STATES = %w[ unknown healthy broken not_configured inconclusive ].freeze
  GRADER_HEALTH_STATES = %w[ unknown healthy broken inconclusive ].freeze
  # Consecutive PollMainBranchHealthJob ticks that fail to reach GitHub
  # (transient network/5xx errors) before a sustained outage degrades an
  # already-broken ci_health to "inconclusive". See main_health_poll_outage?.
  MAIN_HEALTH_POLL_ERROR_STREAK_THRESHOLD = 3

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
  attribute :epic_dependency_policy, :string, default: "linear"
  attribute :fork_pr_grace_period_hours, :integer, default: 24
  attribute :upstream_pr_grace_period_days, :integer, default: 7
  attribute :ci_health, :string, default: "unknown"
  attribute :grader_health, :string, default: "unknown"
  attribute :main_health_poll_error_streak, :integer, default: 0
  attribute :landing_paused, :boolean, default: false
  attribute :main_branch_health_enabled, :boolean, default: true
  attribute :main_branch_repair_enabled, :boolean, default: true
  attribute :main_branch_repair_blocks_work, :boolean, default: true
  attribute :main_branch_repair_auto_approve, :boolean, default: false
  # When on, a scheduled job keeps this fork's default branch in sync with
  # its in-instance upstream (via GitHub's merge-upstream API) so main-branch
  # health/grader detection runs against current code even when no Jobs run.
  # Independent of the per-Job base branch (fork Jobs branch off the upstream
  # directly — see Job#base_on_upstream_default?).
  attribute :fork_auto_sync_enabled, :boolean, default: false
  attribute :external_pr_ingestion_enabled, :boolean, default: false

  attr_accessor :main_branch_repair_enabled_explicit

  enum :ci_health, CI_HEALTH_STATES.index_with(&:itself), prefix: true, validate: true
  enum :grader_health, GRADER_HEALTH_STATES.index_with(&:itself), prefix: true, validate: true

  belongs_to :user, optional: true
  belongs_to :installation, optional: true
  belongs_to :upstream_repository, class_name: "Repository", optional: true, inverse_of: :fork_repositories
  has_many :fork_repositories, class_name: "Repository", foreign_key: :upstream_repository_id, dependent: :nullify, inverse_of: :upstream_repository
  has_many :repository_memberships, dependent: :destroy
  has_many :members, through: :repository_memberships, source: :user
  has_many :team_repositories, dependent: :destroy
  has_many :teams, through: :team_repositories
  has_many :repository_final_approvers, dependent: :destroy
  has_many :final_approvers, through: :repository_final_approvers, source: :user
  has_many :jobs, dependent: :destroy
  has_many :test_identities, dependent: :destroy
  has_many :run_resource_summaries, dependent: :destroy
  has_many :workflow_step_resource_profiles, dependent: :destroy
  has_many :epics, dependent: :destroy
  has_many :scheduled_tasks, dependent: :destroy
  has_many :input_sources, class_name: "InputSource", dependent: :destroy
  has_one :github_input_source, class_name: "InputSources::Github"
  has_one :linear_input_source, class_name: "InputSources::Linear"
  has_many :chat_attachments, as: :attachable, dependent: :destroy
  has_many :chat_sessions, through: :chat_attachments
  has_many :documents, as: :attachable, dependent: :destroy
  has_many :repository_documents, as: :attachable, class_name: "Document", dependent: :destroy
  has_many :chat_pending_actions, dependent: :destroy
  has_many :main_branch_health_checks, dependent: :destroy
  has_many :insight_suggestions, dependent: :destroy
  has_one :insight_schedule_config, dependent: :destroy

  validates :owner, presence: true, format: { with: GITHUB_NAME }
  validates :name, presence: true, format: { with: GITHUB_NAME }
  validates :upstream_owner, format: { with: GITHUB_NAME }, allow_blank: true
  validates :upstream_name, format: { with: GITHUB_NAME }, allow_blank: true
  validates :default_branch, presence: true
  validates :trigger_label, presence: true
  validates :agent_provider, inclusion: { in: -> { User.agent_providers } }, allow_nil: true
  validates :review_policy, presence: true, inclusion: { in: REVIEW_POLICIES }
  validates :feedback_policy, presence: true, inclusion: { in: FEEDBACK_POLICIES }
  validates :epic_dependency_policy, presence: true, inclusion: { in: EPIC_DEPENDENCY_POLICIES }
  validates :name, uniqueness: {
    scope: :owner,
    case_sensitive: false,
    message: "has already been registered for this GitHub owner"
  }
  validate :upstream_owner_and_name_are_paired

  before_validation :normalize_agent_provider
  before_validation :normalize_upstream_metadata
  before_validation :default_main_branch_repair_for_fork, on: :create
  before_save :link_installation_from_owner
  after_create :seed_owner_membership
  after_create :create_github_input_source
  after_save :sync_input_source_attrs, if: -> { saved_change_to_polling_enabled? || saved_change_to_trigger_label? }
  before_destroy :destroy_chat_sessions, prepend: true

  scope :active,   -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  def archived?
    archived_at.present?
  end

  def main_health
    return "unknown" unless main_branch_health_enabled?
    return "broken" if ci_health_broken? || grader_health_broken?
    return "healthy" if grader_health_healthy? && (ci_health_healthy? || ci_health_not_configured?)
    return "inconclusive" if grader_health_inconclusive? || ci_health_inconclusive?

    "unknown"
  end

  def main_health_broken?
    main_health == "broken"
  end

  def main_health_inconclusive?
    main_health == "inconclusive"
  end

  def main_health_unknown?
    main_health == "unknown"
  end

  # Called by PollMainBranchHealthJob when a GitHub call it makes raises a
  # transient error (5xx, timeout, connection failure). A single failure is
  # normal poll-to-poll noise; only a sustained streak should surface as an
  # outage signal.
  def record_main_health_poll_error!
    update_columns(
      main_health_poll_error_streak: main_health_poll_error_streak + 1,
      last_main_health_poll_error_at: Time.current
    )
  end

  def reset_main_health_poll_error_streak!
    update_columns(main_health_poll_error_streak: 0) unless main_health_poll_error_streak.zero?
  end

  def main_health_poll_outage?
    main_health_poll_error_streak >= MAIN_HEALTH_POLL_ERROR_STREAK_THRESHOLD
  end

  # Read-through delegators to the InputSources::Github record.
  # The repository columns remain for legacy reads and fallback when no
  # source record exists yet. Write changes are synced back via after_save.
  def trigger_label
    github_input_source&.config&.dig("trigger_label").presence || read_attribute(:trigger_label)
  end

  def polling_enabled
    source = github_input_source
    return source.polling_enabled if source

    read_attribute(:polling_enabled)
  end

  def polling_enabled?
    !!polling_enabled
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

  def fork?
    upstream_repository_id.present? || upstream_slug.present?
  end

  # The repository whose default branch is the base for Jobs and diffs.
  # For a fork whose upstream is registered in this instance, that's the
  # upstream; otherwise the repository itself. (An external upstream known
  # only by `upstream_slug`, with no in-instance record, falls back to self.)
  def base_repository
    upstream_repository || self
  end

  def base_default_branch
    base_repository.default_branch
  end

  # A fork we can auto-sync: it has an in-instance upstream to merge from.
  def fork_syncable?
    upstream_repository_id.present?
  end

  def effective_agent_provider(user: nil)
    if user
      membership = membership_for(user)
      membership_provider = membership.agent_provider.presence if membership&.at_least?("write")
      return membership_provider if membership_provider
    end
    agent_provider.presence || (user || self.user)&.agent_provider
  end

  def membership_for(user)
    return nil unless user
    repository_memberships.find_by(user_id: user.id)
  end

  def member_at_least?(user, tier)
    role = effective_role_for(user)
    return false unless role
    RepositoryMembership::ROLE_RANK.fetch(role, -1) >= RepositoryMembership::ROLE_RANK.fetch(tier.to_s, 0)
  end

  # Highest of: global admin -> "admin"; direct RepositoryMembership role;
  # best TeamRepository grant across teams `user` belongs to that have a
  # grant on this repository. Teams are purely additive -- a repository
  # with zero TeamRepository grants resolves identically to the
  # direct-membership-only model that preceded teams.
  def effective_role_for(user)
    return nil unless user
    return "admin" if user.admin?

    candidates = [ membership_for(user)&.role, best_team_role_for(user) ].compact
    return nil if candidates.empty?

    candidates.max_by { |role| RepositoryMembership::ROLE_RANK.fetch(role, -1) }
  end

  # Repository ids visible to `user`: direct RepositoryMembership (any
  # tier) plus any repository granted to a team the user belongs to (any
  # tier). Mirrors Job.accessible_to / Epic.accessible_to's "any grant
  # counts" visibility semantics -- callers that need tier-gated access
  # should use #effective_role_for / #member_at_least? instead.
  def self.accessible_repository_ids_for(user)
    return none.select(:id) unless user

    direct_ids = RepositoryMembership.where(user: user).select(:repository_id)
    team_ids = TeamMembership.where(user: user).select(:team_id)
    team_repo_ids = TeamRepository.where(team_id: team_ids).select(:repository_id)
    where(id: direct_ids).or(where(id: team_repo_ids)).select(:id)
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

  # A push/fetch URL carrying a short-lived GitHub token for `user`'s
  # credentials (GithubClient.for prefers the App installation, falls back to
  # the user's PAT). Centralizes the token-acquisition + URL dance that several
  # git services each re-implemented.
  def authenticated_url(user:)
    authenticated_push_url(GithubClient.for(repository: self, user: user).access_token)
  end

  private

  def best_team_role_for(user)
    team_ids = user.team_memberships.select(:team_id)
    team_repositories.where(team_id: team_ids).pluck(:role).max_by { |role| RepositoryMembership::ROLE_RANK.fetch(role, -1) }
  end

  def normalize_agent_provider
    self.agent_provider = nil if agent_provider.blank?
  end

  def normalize_upstream_metadata
    self.upstream_owner = upstream_owner.presence
    self.upstream_name = upstream_name.presence
    self.upstream_default_branch = upstream_default_branch.presence
  end

  def default_main_branch_repair_for_fork
    return if main_branch_repair_enabled_explicit

    self.main_branch_repair_enabled = false if fork?
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
    repository_memberships.find_or_create_by!(user_id: user_id) { |m| m.role = "admin" }
  end

  def create_github_input_source
    return if user_id.nil?

    InputSources::Github.create!(
      repository: self,
      user_id: user_id,
      polling_enabled: read_attribute(:polling_enabled),
      config: { "trigger_label" => read_attribute(:trigger_label) }
    )
    # Validation calls trigger_label / polling_enabled, which loads the
    # association before after_create fires. Reset so the next read queries
    # the record we just persisted.
    association(:github_input_source).reset
  rescue ActiveRecord::RecordNotUnique
    association(:github_input_source).reset
  end

  def sync_input_source_attrs
    source = github_input_source
    return unless source

    updates = {}
    updates[:polling_enabled] = read_attribute(:polling_enabled) if saved_change_to_polling_enabled?
    if saved_change_to_trigger_label?
      updates[:config] = source.config.merge("trigger_label" => read_attribute(:trigger_label))
    end
    source.update_columns(updates) if updates.any?
  end
end
