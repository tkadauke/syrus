class ChatSession < ApplicationRecord
  MESSAGE_PAGE_SIZE = 30
  TITLE_MAX_LENGTH = 60
  TITLE_GENERIC_WORDS = %w[
    app application build change feature idea project request something stuff task thing this tool update
  ].freeze
  TITLE_ACRONYMS = %w[
    AI API CI CLI CSS CSV DB DNS FAQ GitHub HTML HTTP JSON JWT MCP OAuth PDF PR Rails
    REST RSpec SAML SDK SQL SSO UI URL UX VCR
  ].index_by(&:downcase).freeze

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

  after_update_commit :broadcast_header, if: :cumulative_usage_previously_changed?
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

  def self.interpreted_title_for(text, repository: nil)
    fallback = repository_title(repository)
    source = text.to_s.squish
    candidate = interpreted_title_from(source)

    limit_title(candidate.presence || fallback)
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

  class << self
    private

    def repository_title(repository)
      return unless repository

      repository.try(:name).presence || repository.try(:slug).presence
    end

    def interpreted_title_from(source)
      return if source.blank?

      normalized = normalize_title_source(source)
      subject = title_subject(normalized)
      return if generic_title?(subject)

      format_title(subject)
    end

    def normalize_title_source(source)
      source
        .gsub(/!\[[^\]]*\]\([^)]+\)/, " ")
        .gsub(/\[[^\]]+\]\([^)]+\)/) { |match| match[/\A\[([^\]]+)\]/, 1].to_s }
        .gsub(/`([^`]+)`/, '\1')
        .gsub(%r{https?://\S+}, " ")
        .gsub(/[#*_>~]/, " ")
        .squish
    end

    def title_subject(text)
      stripped = strip_request_prefix(text)
      subject = direct_change_subject(stripped) || imperative_subject(stripped) || stripped
      cleanup_subject(subject)
    end

    def strip_request_prefix(text)
      current = text.dup
      loop do
        updated = current.sub(
          /\A(?:please|pls|hey\s+syrus,?|syrus,?|can\s+you|could\s+you|would\s+you|i\s+(?:want|need)\s+(?:you\s+)?to|help\s+me\s+(?:to\s+)?|let'?s)\s+/i,
          ""
        ).squish
        break current if updated == current

        current = updated
      end
    end

    def direct_change_subject(text)
      match = text.match(/\A(?:change|rename|replace|update)\s+(?:the\s+)?(.+?)\s+(?:to|with|from)\b/i)
      match && match[1]
    end

    def imperative_subject(text)
      match = text.match(/\A(?:build|create|make|design|scaffold|prototype|implement|add|fix|repair|update|change|improve|refactor|rename|replace|convert|support|wire\s+up)\s+(?:me\s+|us\s+|a\s+|an\s+|the\s+)?(.+)/i)
      match && match[1]
    end

    def cleanup_subject(subject)
      subject.to_s
        .sub(/\A(?:a|an|the)\s+/i, "")
        .sub(/\s+(?:so\s+that|because|when|if|please)\b.+\z/i, "")
        .sub(/\s+and\s+(?:make|ensure|also|then)\b.+\z/i, "")
        .sub(/[.!?].+\z/, "")
        .sub(/[,;:]\z/, "")
        .sub(/\s+for\s+(?:me|us)\z/i, "")
        .sub(/\s+in\s+(?:this|the)\s+(?:repo|repository|project)\z/i, "")
        .gsub(/[\"'“”‘’]/, "")
        .squish
    end

    def generic_title?(subject)
      words = subject.to_s.downcase.scan(/[a-z0-9]+/)
      return true if words.empty?

      words.all? { |word| TITLE_GENERIC_WORDS.include?(word) }
    end

    def format_title(subject)
      titled = subject.split(/\s+/).map { |word| title_word(word) }.join(" ")
      limit_title(titled)
    end

    def title_word(word)
      leading = word[/\A[^[:alnum:]]*/].to_s
      trailing = word[/[^[:alnum:]]*\z/].to_s
      core = word[leading.length...(word.length - trailing.length)].to_s
      acronym = TITLE_ACRONYMS[core.downcase]
      return "#{leading}#{acronym}#{trailing}" if acronym

      "#{leading}#{core.downcase.capitalize}#{trailing}"
    end

    def limit_title(title)
      value = title.to_s.squish
      return if value.blank?
      return value if value.length <= TITLE_MAX_LENGTH

      trimmed = value[0, TITLE_MAX_LENGTH].sub(/\s+\S*\z/, "").squish
      trimmed.presence || value[0, TITLE_MAX_LENGTH]
    end
  end

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

  def cumulative_usage_previously_changed?
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
