class ChatMessage < ApplicationRecord
  ROLES = %w[ user assistant tool_use tool_result system ].freeze
  SPA_EVENT_TAIL_SIZE = 24

  belongs_to :chat_session
  belongs_to :proposal, class_name: "ChatProposal", optional: true
  belongs_to :pending_action, class_name: "ChatPendingAction", optional: true

  has_many :bookmarks, class_name: "ChatBookmark", dependent: :destroy, inverse_of: :chat_message
  has_many :scoped_events, class_name: "ChatScopedEvent", dependent: :nullify

  after_create :record_chat_turn_state
  after_create_commit :broadcast_app_event
  after_create_commit :enqueue_search_index
  after_create_commit :clear_suggested_next_step, if: -> { role == "user" }

  validates :role, presence: true, inclusion: { in: ROLES }
  validate :content_is_present

  def bookmarkable?
    role.in?(%w[user assistant])
  end

  # Returns true when the content column uses the Anthropic messages API
  # content-blocks format (the canonical representation). Legacy rows use
  # a flat hash keyed on "text", "input", or "result". Rehydrators and
  # serializers use this to handle both formats without migrating old rows.
  def canonical_content_format?
    case role
    when "assistant"
      content.is_a?(Array)
    when "tool_use", "tool_result"
      content.is_a?(Hash) && content.key?("type")
    else
      true
    end
  end

  private

  def content_is_present
    errors.add(:content, "can't be blank") if content.nil?
  end

  def broadcast_app_event
    chat = chat_session
    tail = chat.messages
               .includes(:pending_action, proposal: [ :repository, :job, :epic, :target_epic, dependencies: [], child_proposals: [ :repository, dependencies: [] ] ])
               .order(created_at: :desc, id: :desc)
               .limit(SPA_EVENT_TAIL_SIZE)
               .to_a
               .reverse

    AppEvents.broadcast(
      user: chat.user,
      type: "updated",
      resource: "chat",
      id: chat_session_id,
      changed: [ "messages" ],
      payload: {
        action: "replace_tail",
        replace_from_id: tail.first&.id,
        messages: ::App::ChatMessagePayload.messages(tail, repository: chat.repository),
        turn_in_flight: chat.turn_in_flight?,
        agent_busy: chat.agent_busy?,
        stop_requested_at: chat.stop_requested_at&.iso8601,
        queued_messages: chat.queued_messages_payload
      }
    )
  end

  def record_chat_turn_state
    chat_session.record_message_turn_state!(self)
  end

  def enqueue_search_index
    IndexChatMessageJob.perform_later(id) if ChatMessageSearchIndex.indexable?(self)
  end

  # A stored next-step suggestion is only valid until the operator speaks
  # again — clear it the moment a user message lands.
  def clear_suggested_next_step
    chat_session&.clear_suggested_next_step!
  end
end
