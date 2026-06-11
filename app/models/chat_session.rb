class ChatSession < ApplicationRecord
  MESSAGE_PAGE_SIZE = 30
  TITLE_MAX_LENGTH = 60

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
  has_many :bookmarks,
           -> { order("chat_messages.created_at ASC", "chat_messages.id ASC", "chat_bookmarks.id ASC") },
           through: :messages,
           source: :bookmarks
  has_many :proposals, class_name: "ChatProposal", dependent: :destroy
  has_many :pending_actions, class_name: "ChatPendingAction", dependent: :destroy
  has_one :claude_session, as: :resumable, dependent: :destroy
  has_one :whiteboard, dependent: :destroy

  after_update_commit :broadcast_header, if: :header_previously_changed?
  after_create :attach_initial_repository
  before_destroy :destroy_workspace

  validates :cumulative_input_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cumulative_output_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cumulative_cost_usd,
            numericality: { greater_than_or_equal_to: 0 }

  scope :attached_to_repository, ->(repository) {
    joins(:chat_attachments)
      .where(chat_attachments: { attachable_type: "Repository", attachable_id: repository.id })
  }

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
  def broadcast_controls(app_event: true)
    broadcast_app_controls_update if app_event
  end

  private

  def broadcast_app_header_update
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
          stop_requested_at: stop_requested_at&.iso8601,
          cumulative_input_tokens: cumulative_input_tokens.to_i,
          cumulative_output_tokens: cumulative_output_tokens.to_i,
          cumulative_cost_usd: cumulative_cost.to_f
        }
      }
    )
  end

  def broadcast_app_controls_update
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
        stop_requested_at: stop_requested_at&.iso8601
      }
    )
  end

  def header_previously_changed?
    saved_change_to_title? ||
      saved_change_to_cumulative_input_tokens? ||
      saved_change_to_cumulative_output_tokens? ||
      saved_change_to_cumulative_cost_usd?
  end

  def attach_initial_repository
    return unless @initial_repository

    chat_attachments.create!(attachable: @initial_repository)
  end

  def destroy_workspace
    ChatWorkspace.destroy!(self)
  end

  def attached_records_for(type)
    klass = type.safe_constantize
    return [] unless klass

    klass.where(id: chat_attachments.where(attachable_type: type).select(:attachable_id))
  end
end
