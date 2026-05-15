class Repository < ApplicationRecord
  GITHUB_NAME = /\A[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?\z/
  OPERATOR_CHAT_CHANNELS = %w[ disabled in_syrus telegram ].freeze

  attribute :polling_enabled, :boolean, default: true
  attribute :prepare_enabled, :boolean, default: true
  attribute :pr_cost_footer_enabled, :boolean, default: true
  attribute :auto_merge_enabled, :boolean, default: false
  attribute :allow_operator_chat, :string, default: "disabled"

  belongs_to :user
  belongs_to :installation, optional: true
  has_many :jobs, dependent: :destroy
  has_many :scheduled_tasks, dependent: :destroy
  has_many :chat_attachments, as: :attachable, dependent: :destroy
  has_many :chat_sessions, through: :chat_attachments
  has_many :repository_notes, dependent: :destroy
  has_many :repository_documents, dependent: :destroy
  has_one :repository_whiteboard, dependent: :destroy
  has_many :chat_pending_actions, dependent: :destroy
  has_many :operator_questions, through: :jobs

  validates :owner, presence: true, format: { with: GITHUB_NAME }
  validates :name, presence: true, format: { with: GITHUB_NAME }
  validates :default_branch, presence: true
  validates :trigger_label, presence: true
  validates :allow_operator_chat, presence: true, inclusion: { in: OPERATOR_CHAT_CHANNELS }
  validates :agent_provider, inclusion: { in: User::AGENT_PROVIDERS }, allow_nil: true
  validates :allow_operator_chat, presence: true, inclusion: { in: OPERATOR_CHAT_CHANNELS }
  validates :owner, uniqueness: { scope: [ :user_id, :name ], case_sensitive: false }

  before_validation :normalize_agent_provider
  before_save :link_installation_from_owner
  before_destroy :destroy_chat_sessions, prepend: true
  before_destroy :destroy_chat_workspace

  scope :active,   -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  def archived?
    archived_at.present?
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

  def effective_agent_provider
    agent_provider.presence || user.agent_provider
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

  def link_installation_from_owner
    return unless will_save_change_to_owner? || installation_id.blank?
    self.installation = InstallationLinker.find_for_owner(owner)
  end

  def destroy_chat_workspace
    ChatWorkspace.destroy!(self)
  end

  def destroy_chat_sessions
    chat_sessions.find_each(&:destroy)
  end
end
