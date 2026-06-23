class ChatMessage < ApplicationRecord
  ROLES = %w[ user assistant tool_use tool_result system ].freeze
  SPA_EVENT_TAIL_SIZE = 24

  belongs_to :chat_session
  belongs_to :proposal, class_name: "ChatProposal", optional: true
  belongs_to :pending_action, class_name: "ChatPendingAction", optional: true

  has_many :bookmarks, class_name: "ChatBookmark", dependent: :destroy, inverse_of: :chat_message

  after_create_commit :broadcast_app_event
  after_create_commit :enqueue_search_index

  validates :role, presence: true, inclusion: { in: ROLES }
  validate :content_is_present

  def bookmarkable?
    role.in?(%w[user assistant])
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

  def enqueue_search_index
    IndexChatMessageJob.perform_later(id) if ChatMessageSearchIndex.indexable?(self)
  end
end
