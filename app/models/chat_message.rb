class ChatMessage < ApplicationRecord
  include EnqueuesSearchIndex

  ROLES = %w[ user assistant tool_use tool_result system ].freeze
  SPA_EVENT_TAIL_SIZE = 24
  PREVIEW_TEXT_MAX_BYTES = 500

  belongs_to :chat_session
  belongs_to :proposal, class_name: "ChatProposal", optional: true
  belongs_to :pending_action, class_name: "ChatPendingAction", optional: true
  belongs_to :sender_user, class_name: "User", optional: true

  has_many :bookmarks, class_name: "ChatBookmark", dependent: :destroy, inverse_of: :chat_message
  has_many :pins, class_name: "ChatMessagePin", dependent: :destroy, inverse_of: :chat_message
  has_many :scoped_events, class_name: "ChatScopedEvent", dependent: :nullify

  # Set by callers that already know this user message will not trigger a
  # ChatTurnJob (e.g. an unmentioned message in a group chat), so the
  # after_create callback below doesn't flip turn_in_flight on for a turn
  # that will never run and clear it.
  attr_accessor :skip_turn_trigger

  after_create :record_chat_turn_state
  after_create_commit :broadcast_app_event
  after_create_commit :enqueue_search_index
  after_create_commit :clear_suggested_next_step, if: -> { role == "user" }
  after_create_commit :deliver_to_platform, if: :platform_delivery_needed?

  validates :role, presence: true, inclusion: { in: ROLES }
  validate :content_is_present

  def bookmarkable?
    role.in?(%w[user assistant])
  end

  def pinnable?
    role.in?(%w[user assistant])
  end

  def sender
    role == "user" ? sender_user : nil
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

  # Single-line preview text for surfaces like the pinned-messages bar —
  # collapses whitespace/newlines and caps length so a long message can't
  # blow up a compact UI row.
  def preview_text
    extract_text_from_content.to_s.gsub(/[[:space:]]+/, " ").strip.safe_byteslice(0, PREVIEW_TEXT_MAX_BYTES)
  end

  private

  def extract_text_from_content
    if content.is_a?(Array)
      content.filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" }.join
    elsif content.is_a?(Hash)
      content["text"].to_s
    else
      content.to_s
    end
  end

  def content_is_present
    errors.add(:content, "can't be blank") if content.nil?
  end

  def broadcast_app_event
    chat = chat_session
    tail = chat.messages
               .includes(:pending_action, proposal: [ :repository, :job, :epic, :target_epic, dependencies: [], child_proposals: [ :repository, dependencies: [] ] ])
               .order(id: :desc)
               .limit(SPA_EVENT_TAIL_SIZE)
               .to_a
               .reverse

    event_args = {
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
    }

    chat.send(:broadcast_to_participants, **event_args)
  end

  def record_chat_turn_state
    chat_session.record_message_turn_state!(self, trigger_turn: !skip_turn_trigger)
  end

  def enqueue_search_index
    enqueue_search_index_job(IndexChatMessageJob, id) if ChatMessageSearchIndex.indexable?(self)
  end

  def clear_suggested_next_step
    chat_session&.clear_suggested_next_step!
  end

  def platform_delivery_needed?
    role == "assistant" && chat_session.origin_platform.present?
  end

  def deliver_to_platform
    platform = chat_session.origin_platform
    return unless PlatformDelivery::Registry.registered?(platform)

    adapter = PlatformDelivery::Registry.for(platform)
    chat_session.participants.each do |participant|
      identity = participant.platform_identities.find_by(platform: platform)
      next unless identity
      adapter.deliver(message: self, platform_identity: identity)
    end
  end
end
