class ChatSession < ApplicationRecord
  MESSAGE_PAGE_SIZE = 30
  TITLE_MAX_LENGTH = 120
  SUGGESTED_NEXT_STEP_MAX_BYTES = 200

  belongs_to :user

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
  has_many :messages, class_name: "ChatMessage", dependent: :destroy
  has_many :chat_queued_messages, class_name: "ChatQueuedMessage", dependent: :destroy
  has_many :queued_messages, -> { pending.order(:created_at, :id) }, class_name: "ChatQueuedMessage"
  has_many :scratchpad_items, -> { ordered }, class_name: "ChatScratchpadItem", dependent: :destroy
  has_many :video_walkthroughs, class_name: "ChatVideoWalkthrough", dependent: :destroy
  has_many :wakeups, class_name: "ChatWakeup", dependent: :destroy
  has_many :agent_questions, class_name: "ChatAgentQuestion", dependent: :destroy
  has_many :bookmarks,
           -> { order("chat_messages.created_at ASC", "chat_messages.id ASC", "chat_bookmarks.id ASC") },
           through: :messages,
           source: :bookmarks
  has_many :proposals, class_name: "ChatProposal", dependent: :destroy
  has_many :pending_actions, class_name: "ChatPendingAction", dependent: :destroy
  has_many :whiteboard_snapshots, dependent: :destroy
  has_one :claude_session, as: :resumable, dependent: :destroy
  has_one :whiteboard, dependent: :destroy

  after_update_commit :broadcast_header, if: :header_previously_changed?
  after_create :attach_initial_repository
  # prepend: dependent-association callbacks (declared above) also run
  # as before_destroy; the pending JobDependency placeholders must be
  # released BEFORE `dependent: :destroy` deletes the proposals they
  # reference, or the proposal delete raises InvalidForeignKey.
  before_destroy :release_unresolved_proposal_dependencies, prepend: true
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
  MODES = %w[ planning coding ].freeze

  enum :mode, { planning: "planning", coding: "coding" }, default: "planning"

  validates :chat_provider, inclusion: { in: User::CHAT_PROVIDERS }, allow_nil: true
  validates :share_token, uniqueness: true, allow_nil: true

  normalizes :chat_provider, with: ->(value) { value.to_s.strip.presence }

  scope :attached_to_repository, ->(repository) {
    joins(:chat_attachments)
      .where(chat_attachments: { attachable_type: "Repository", attachable_id: repository.id })
  }
  scope :visible, -> { where(hidden_at: nil) }
  scope :hidden, -> { where.not(hidden_at: nil) }

  def self.fallback_title_for(repository)
    return unless repository

    repository.try(:name).presence || repository.try(:slug).presence
  end

  def title_pending?
    title.blank? && messages.where(role: "user").exists?
  end

  def repository=(repository)
    @initial_repository = repository
  end

  def repository
    attached_repositories.first || @initial_repository
  end

  def repository_id
    repository&.id
  end

  def effective_chat_provider
    chat_provider.presence || user&.effective_chat_provider || "claude"
  end

  def workspace_root
    ChatWorkspace.path_for(self)
  end

  def attached_documents
    records = attached_records_for("Document")
    records.to_a
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
    latest_user_message = messages.where(role: "user").order(:created_at, :id).last
    return false unless latest_user_message

    messages
      .where("created_at > ? OR (created_at = ? AND id > ?)",
             latest_user_message.created_at,
             latest_user_message.created_at,
             latest_user_message.id)
      .where.not(role: "user")
      .none?
  end

  def agent_busy?
    SpawnedProcess.running
                  .where(kind: "agent", workdir: workspace_root.to_s)
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
    AppEvents.broadcast(
      user: user,
      type: "updated",
      resource: "chat",
      id: id,
      changed: [ "header" ],
      payload: {
        action: "update_header",
        chat: {
          title: title,
          title_pending: title_pending?,
          pinned_context: pinned_context,
          chat_provider: effective_chat_provider,
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

  def broadcast_app_suggestion_update
    AppEvents.broadcast(
      user: user,
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
    AppEvents.broadcast(
      user: user,
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

  private

  def header_previously_changed?
    saved_change_to_title? ||
      saved_change_to_pinned_context? ||
      saved_change_to_chat_provider? ||
      saved_change_to_mode? ||
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

  def attached_records_for(type)
    klass = type.safe_constantize
    return [] unless klass

    klass.where(id: chat_attachments.where(attachable_type: type).select(:attachable_id))
  end
end
