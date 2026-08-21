class ChatSession < ApplicationRecord
  MESSAGE_PAGE_SIZE = 30
  TITLE_MAX_LENGTH = 120
  SUGGESTED_NEXT_STEP_MAX_BYTES = 200
  MODES = %w[planning coding local].freeze
  SYSTEM_KINDS = %w[supervisor].freeze
  DAEMON_STATES = %w[connected disconnected].freeze
  EFFORT_LEVELS = %w[none medium high].freeze
  CONVERSATION_KINDS = { direct: "direct", group: "group" }.freeze

  TRIGGER_POLICIES = %w[speak_when_spoken_to].freeze

  belongs_to :user

  has_many :chat_participants, dependent: :destroy
  has_many :participants, through: :chat_participants, source: :user
  has_one :owner_participant,
          -> { where(role: "owner") },
          class_name: "ChatParticipant",
          inverse_of: :chat_session

  has_many :chat_attachments, dependent: :destroy
  has_many :repository_attachments,
           -> { where(attachable_type: "Repository").order(:attached_at, :id) },
           class_name: "ChatAttachment"
  has_many :job_attachments,
           -> { where(attachable_type: "Job").order(:attached_at, :id) },
           class_name: "ChatAttachment"
  has_many :epic_attachments,
           -> { where(attachable_type: "Epic").order(:attached_at, :id) },
           class_name: "ChatAttachment"
  has_many :repository_document_attachments,
           -> { where(attachable_type: "Document").order(:attached_at, :id) },
           class_name: "ChatAttachment"
  has_many :attached_repositories,
           through: :repository_attachments,
           source: :attachable,
           source_type: "Repository"
  has_many :attached_jobs,
           through: :job_attachments,
           source: :attachable,
           source_type: "Job"
  has_many :attached_epics,
           through: :epic_attachments,
           source: :attachable,
           source_type: "Epic"
  has_many :attached_repository_documents,
           through: :repository_document_attachments,
           source: :attachable,
           source_type: "Document"
  has_many :messages, class_name: "ChatMessage", dependent: :destroy, inverse_of: :chat_session
  has_many :context_checkpoints, class_name: "ChatContextCheckpoint", dependent: :destroy
  has_many :scoped_events, class_name: "ChatScopedEvent", dependent: :destroy
  has_many :mcp_tool_usages, dependent: :nullify
  has_many :chat_queued_messages, class_name: "ChatQueuedMessage", dependent: :destroy
  has_many :queued_messages, -> { pending.order(:created_at, :id) }, class_name: "ChatQueuedMessage"
  has_many :scratchpad_items, -> { ordered }, class_name: "ChatScratchpadItem", dependent: :destroy
  has_many :video_walkthroughs, class_name: "ChatVideoWalkthrough", dependent: :destroy
  has_many :wakeups, class_name: "ChatWakeup", dependent: :destroy
  has_many :scheduled_messages, class_name: "ScheduledChatMessage", dependent: :destroy
  has_many :agent_questions, class_name: "ChatAgentQuestion", dependent: :destroy
  has_many :bookmarks,
           -> { order("chat_messages.created_at ASC", "chat_messages.id ASC", "chat_bookmarks.id ASC") },
           through: :messages,
           source: :bookmarks
  has_many :proposals, class_name: "ChatProposal", dependent: :destroy
  has_many :pending_actions, class_name: "ChatPendingAction", dependent: :destroy
  has_many :whiteboard_snapshots, dependent: :destroy
  has_one :provider_session, as: :resumable, dependent: :destroy
  has_one :provider_session_metadata,
          -> { metadata_only },
          as: :resumable,
          class_name: "ProviderSession"
  has_one :whiteboard, dependent: :destroy
  has_one :linked_job, class_name: "Job", foreign_key: :linked_chat_id, inverse_of: :linked_chat, dependent: :nullify
  has_one :local_daemon_session, dependent: :destroy

  # MySQL 8 rejects defaults on JSON columns, so seed `{}` on new records
  # via after_initialize instead of a column default. Existing rows were
  # backfilled by the AddArtifactsToChatSessions migration.
  after_initialize :default_artifacts, if: :new_record?
  after_update_commit :broadcast_header, if: :header_previously_changed?
  before_validation :seed_chat_provider, on: :create
  after_create :attach_initial_repository
  after_create :add_owner_participant
  # prepend: dependent-association callbacks (declared above) also run
  # as before_destroy; the pending JobDependency placeholders must be
  # released BEFORE `dependent: :destroy` deletes the proposals they
  # reference, or the proposal delete raises InvalidForeignKey.
  before_destroy :release_unresolved_proposal_dependencies, prepend: true
  before_destroy :prevent_enabled_supervisor_destroy, prepend: true
  # Filesystem + FTS cleanup is deliberately NOT done here: it runs
  # post-commit on the worker via ChatSessionCleanupJob, so a rollback
  # can't leave irreversible side effects behind and the rm_rf happens
  # on the pod that actually mounts the workspace PVC.
  after_destroy_commit :enqueue_cleanup_job

  validates :title, length: { maximum: TITLE_MAX_LENGTH }, allow_nil: true
  validates :cumulative_input_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cumulative_output_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cumulative_cost_usd,
            numericality: { greater_than_or_equal_to: 0 }
  enum :mode, { planning: "planning", coding: "coding", local: "local" }, validate: { allow_nil: true }
  enum :system_kind, { supervisor: "supervisor" }, prefix: true, validate: { allow_nil: true }
  # scopes: false — an auto-generated `.group` scope would shadow
  # ActiveRecord's GROUP BY `group` method, which admin chat listing
  # relies on (Api::V1::Admin::ChatsController#index).
  enum :conversation_kind, CONVERSATION_KINDS, scopes: false, validate: true
  validate :conversation_kind_is_immutable, if: -> { persisted? && conversation_kind_changed? }

  validates :chat_provider, presence: true, if: :persisted?
  validates :chat_provider, inclusion: { in: -> { User.chat_providers } }, allow_nil: true
  validates :chat_model, length: { maximum: 100 }, allow_nil: true
  validates :local_daemon_state, inclusion: { in: DAEMON_STATES }, allow_nil: true
  validates :chat_effort, inclusion: { in: EFFORT_LEVELS }, allow_nil: true
  validates :share_token, uniqueness: true, allow_nil: true
  validates :system_kind, uniqueness: { scope: :user_id }, allow_nil: true
  validate :enabled_supervisor_affordance_is_preserved, if: :enabled_supervisor_chat?
  enum :trigger_policy, { speak_when_spoken_to: "speak_when_spoken_to" }, validate: true

  normalizes :chat_provider, with: ->(value) { value.to_s.strip.presence }
  normalizes :chat_model, with: ->(value) { value.to_s.strip.presence }
  normalizes :mode, with: ->(value) { value.to_s.strip.presence }
  normalizes :system_kind, with: ->(value) { value.to_s.strip.presence }

  scope :attached_to_repository, ->(repository) {
    joins(:chat_attachments)
      .where(chat_attachments: { attachable_type: "Repository", attachable_id: repository.id })
  }
  scope :visible, -> { where(hidden_at: nil) }
  scope :hidden, -> { where.not(hidden_at: nil) }
  scope :ordinary_chats, -> { where(system_kind: nil) }

  def self.fallback_title_for(repository)
    return unless repository

    repository.try(:name).presence || repository.try(:slug).presence
  end

  def self.for_platform(user:, platform:)
    existing = joins(:chat_participants)
      .where(origin_platform: platform, chat_participants: { user_id: user.id })
      .first
    return existing if existing

    transaction do
      session = create!(
        user: user,
        trigger_policy: "speak_when_spoken_to",
        origin_platform: platform
      )
      session
    end
  end

  def user
    owner_participant&.user || super
  end

  def title_pending?
    title.blank? && ChatMessage.where(chat_session_id: id, role: "user").exists?
  end

  def supervisor_chat?
    system_kind == "supervisor"
  end

  def repository=(repository)
    @initial_repository = repository
  end

  def repository
    if association(:repository_attachments).loaded?
      return repository_attachments.first&.attachable || @initial_repository
    end

    attached_repositories.first || @initial_repository
  end

  def repository_id
    repository&.id
  end

  # Read-or-default convenience for artifact access, mirroring
  # Workflow#artifact. Nil-safe against a freshly-created ChatSession
  # whose `artifacts` column hasn't been touched yet.
  def artifact(key)
    (artifacts || {})[key.to_s]
  end

  # Append-only artifact write, mirroring Workflow#set_artifact!.
  def set_artifact!(key, value)
    self.artifacts = (artifacts || {}).merge(key.to_s => value)
    save!
  end

  def effective_chat_provider
    chat_provider.presence || "claude"
  end

  def pin_chat_provider!(provider = nil, broadcast: true)
    resolved_provider = provider.to_s.strip.presence || initial_chat_provider
    return chat_provider if chat_provider.present?

    unless User.chat_providers.include?(resolved_provider)
      errors.add(:chat_provider, "is not included in the list")
      raise ActiveRecord::RecordInvalid, self
    end

    if broadcast
      update!(chat_provider: resolved_provider)
    else
      update_columns(chat_provider: resolved_provider)
      self.chat_provider = resolved_provider
    end

    chat_provider
  end

  def initial_chat_provider
    user&.effective_chat_provider || "claude"
  end

  def workspace_root
    ChatWorkspace.path_for(self)
  end

  def attached_documents
    records = attached_records_for("Document")
    records.to_a
  end

  def seed_chat_provider
    self.chat_provider ||= initial_chat_provider
  end

  def attached_documents_in_scope
    repository_ids = attached_repositories.ids + attached_jobs.includes(:repository).map(&:repository_id)
    document_ids = attached_documents.map(&:id)

    Document
      .where(user_id: user_id)
      .where(attachable_type: "Repository", attachable_id: repository_ids.uniq)
      .or(Document.where(user_id: user_id, id: document_ids))
      .distinct
  end

  def turn_in_flight?
    self[:turn_in_flight]
  end

  def record_message_turn_state!(message, trigger_turn: true)
    in_flight = message.role == "user" && trigger_turn
    update_columns(
      turn_in_flight: in_flight,
      last_message_at: message.created_at || Time.current
    )
    self.last_message_at = message.created_at || Time.current
    self.turn_in_flight = in_flight
  end

  def recalculate_turn_state!
    latest_user_message = messages.where(role: "user").order(:created_at, :id).last
    next_value = if latest_user_message
      messages
        .where("created_at > ? OR (created_at = ? AND id > ?)",
               latest_user_message.created_at,
               latest_user_message.created_at,
               latest_user_message.id)
        .where.not(role: "user")
        .none?
    else
      false
    end

    update_columns(turn_in_flight: next_value)
    self.turn_in_flight = next_value
    next_value
  end

  def agent_busy?
    SpawnedProcess.live_agent
                  .where(workdir: workspace_root.to_s)
                  .exists?
  end

  def cumulative_cost
    cumulative_cost_usd.to_d
  end

  def record_turn_usage!(result)
    updates = {}
    updates[:cumulative_input_tokens] = cumulative_input_tokens + result.input_tokens.to_i if result.input_tokens
    updates[:cumulative_output_tokens] = cumulative_output_tokens + result.output_tokens.to_i if result.output_tokens
    updates[:cumulative_cost_usd] = cumulative_cost + result.cost_usd.to_d if result.cost_usd
    update!(updates) if updates.any?
  end

  def broadcast_header
    broadcast_app_header_update
  end

  # Chat controls are rendered by React from typed app-event payloads.
  # ChatMessage tail events already carry the active-turn state, so
  # callers can suppress this duplicate event when appropriate.
  def broadcast_controls(app_event: true, switching_provider: false)
    broadcast_app_controls_update(switching_provider: switching_provider) if app_event
  end

  def queued_messages_payload
    queued_messages.map do |message|
      {
        id: message.id,
        text: message.text,
        created_at: message.created_at&.iso8601,
        app_update_path: "/api/v1/app/chats/#{id}/queued_messages/#{message.id}",
        app_delete_path: "/api/v1/app/chats/#{id}/queued_messages/#{message.id}"
      }
    end
  end

  def scratchpad_items_payload
    scratchpad_items.map do |item|
      {
        id: item.id,
        content: item.content,
        app_update_path: "/api/v1/app/chats/#{id}/scratchpad_items/#{item.id}",
        app_delete_path: "/api/v1/app/chats/#{id}/scratchpad_items/#{item.id}"
      }
    end
  end

  def agent_questions_payload
    agent_questions.active.map do |question|
      {
        id: question.id,
        question: question.question,
        options: question.options,
        asked_at: question.asked_at&.iso8601,
        app_answer_path: "/api/v1/app/chats/#{id}/agent_questions/#{question.id}/answer"
      }
    end
  end

  def broadcast_app_header_update
    repository = self.repository
    effective_provider = effective_chat_provider
    broadcast_to_participants(
      type: "updated",
      resource: "chat",
      id: id,
      changed: [ "header" ],
      payload: {
        action: "update_header",
        chat: {
          title: title,
          title_pending: title_pending?,
          system_kind: system_kind,
          pinned_context: pinned_context,
          chat_provider: effective_provider,
          effective_chat_provider: effective_provider,
          effective_chat_provider_label: App::Presentation.agent_provider_label(effective_provider),
          provider_availability: App::ProviderAvailability.for_user(user, effective_provider),
          mode: mode,
          local_daemon_state: local_daemon_state,
          local_daemon_repo: local_daemon_repo,
          local_daemon_branch: local_daemon_branch,
          repository: repository ? { id: repository.id, slug: repository.slug } : nil,
          stop_requested_at: stop_requested_at&.iso8601,
          cumulative_input_tokens: cumulative_input_tokens.to_i,
          cumulative_output_tokens: cumulative_output_tokens.to_i,
          cumulative_cost_usd: cumulative_cost.to_f,
          coding_checkout_uncommitted: coding_checkout_uncommitted?
        }
      }
    )
  end

  # Stores the agent's tab-completable next-step suggestion, clamped to
  # SUGGESTED_NEXT_STEP_MAX_BYTES via safe_byteslice so multibyte
  # characters are never split. Returns the stored text, or nil when the
  # clamped text is blank.
  def record_suggested_next_step!(text)
    clamped = text.to_s.strip.safe_byteslice(0, SUGGESTED_NEXT_STEP_MAX_BYTES).to_s.strip
    return if clamped.blank?

    update!(suggested_next_step: clamped)
    broadcast_app_suggestion_update
    clamped
  end

  def clear_suggested_next_step!
    return if suggested_next_step.blank?

    update!(suggested_next_step: nil)
    broadcast_app_suggestion_update
  end

  def broadcast_daemon_status(status, repo: nil, branch: nil)
    payload = {
      action: "update_daemon_status",
      daemon_connected: daemon_connected?,
      daemon_status: status,
      daemon_repo: repo || daemon_repo,
      daemon_branch: branch || daemon_branch
    }
    broadcast_to_participants(
      type: "updated",
      resource: "chat",
      id: id,
      changed: [ "daemon" ],
      payload: payload
    )
  end

  def daemon_connected?
    daemon_connected
  end

  def broadcast_app_suggestion_update
    broadcast_to_participants(
      type: "updated",
      resource: "chat",
      id: id,
      changed: [ "suggestion" ],
      payload: {
        action: "update_suggestion",
        suggested_next_step: suggested_next_step
      }
    )
  end

  def broadcast_app_controls_update(switching_provider: false)
    broadcast_to_participants(
      type: "updated",
      resource: "chat",
      id: id,
      changed: [ "controls" ],
      payload: {
        action: "update_controls",
        turn_in_flight: turn_in_flight?,
        agent_busy: agent_busy?,
        stop_requested_at: stop_requested_at&.iso8601,
        switching_provider: switching_provider,
        queued_messages: queued_messages_payload,
        scratchpad_items: scratchpad_items_payload
      }
    )
  end

  def enabled_supervisor_chat?
    supervisor_chat? && Feature.admin_supervisor_chat_enabled?
  end

  # Plain-text, case-insensitive `@syrus` substring match — no
  # autocomplete/chip UI in this pass. Mirrors Telegram's own
  # plain-text bot-mention convention so this stays compatible with a
  # future Telegram-group bridge.
  def agent_addressed?(text)
    text.to_s.downcase.include?("@syrus")
  end

  # Computed live from current human headcount, not a stored/toggleable
  # setting: chats with 0-1 participants always trigger the agent; chats
  # with 2+ participants require an explicit @syrus mention on every message.
  def should_trigger_agent?(text)
    chat_participants.count <= 1 || agent_addressed?(text)
  end

  def participants_payload
    chat_participants.includes(:user).order(:joined_at, :id).map do |participant|
      {
        id: participant.user_id,
        name: participant.user.display_name,
        avatar_url: participant.user.avatar_url,
        role: participant.role
      }
    end
  end

  # `recipients` lets callers notify a user who is no longer a
  # participant by the time this fires (e.g. a just-removed member) —
  # the default falls back to the current live participant set.
  def broadcast_participants_update!(recipients: nil)
    broadcast_to_participants(
      recipients: recipients,
      type: "updated",
      resource: "chat",
      id: id,
      changed: [ "participants" ],
      payload: {
        action: "update_participants",
        conversation_kind: conversation_kind,
        participants: participants_payload
      }
    )
  end

  private

  def broadcast_to_participants(recipients: nil, **event_args)
    (recipients || participants.to_a.presence || [ user ]).each do |p|
      AppEvents.broadcast(user: p, **event_args)
    end
  end

  def add_owner_participant
    chat_participants.create!(user: user, role: "owner", joined_at: created_at)
  end

  def default_artifacts
    self.artifacts ||= {}
  end

  def header_previously_changed?
    saved_change_to_title? ||
      saved_change_to_pinned_context? ||
      saved_change_to_chat_provider? ||
      saved_change_to_chat_model? ||
      saved_change_to_mode? ||
      saved_change_to_local_daemon_state? ||
      saved_change_to_local_daemon_repo? ||
      saved_change_to_local_daemon_branch? ||
      saved_change_to_cumulative_input_tokens? ||
      saved_change_to_cumulative_output_tokens? ||
      saved_change_to_cumulative_cost_usd? ||
      saved_change_to_coding_checkout_uncommitted?
  end

  def attach_initial_repository
    return unless @initial_repository

    chat_attachments.create!(attachable: @initial_repository, suppress_header_broadcast: true)
  end

  # Pending JobDependency rows can reference this chat's proposals via
  # unresolved_chat_proposal_id (a placeholder awaiting a proposal that
  # will now never materialize). Such rows can never resolve once the
  # proposal is gone — dependency_succeeded? would stay false forever
  # and wedge the dependent Job — so they are removed, not nullified:
  # a JobDependency must reference exactly one target, and a
  # target-less row is both invalid and permanently blocking.
  def release_unresolved_proposal_dependencies
    JobDependency.where(unresolved_chat_proposal_id: proposals.select(:id)).delete_all
  end

  def enqueue_cleanup_job
    ChatSessionCleanupJob.perform_later(id, workspace_path)
  end

  def enabled_supervisor_affordance_is_preserved
    errors.add(:title, "cannot be changed for the supervisor chat") if title_changed? && persisted?
    errors.add(:pinned, "cannot be disabled for the supervisor chat") if pinned == false
    errors.add(:hidden_at, "cannot be set for the supervisor chat") if hidden_at.present?
  end

  def conversation_kind_is_immutable
    errors.add(:conversation_kind, "cannot be changed after creation")
  end

  def prevent_enabled_supervisor_destroy
    return unless enabled_supervisor_chat?

    errors.add(:base, "Supervisor chat cannot be deleted while the feature is enabled")
    throw :abort
  end

  def attached_records_for(type)
    klass = type.safe_constantize
    return [] unless klass

    klass.where(id: chat_attachments.where(attachable_type: type).select(:attachable_id))
  end
end
