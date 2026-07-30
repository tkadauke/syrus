# Chat-session lifecycle helpers extracted from Api::V1::App::ChatsController:
# creating a chat session (+ enqueuing its title / first turn), finding the
# target session, and branching a chat from a source (title, source lookup,
# message copy). Pure controller helpers, mixed straight back in. Kept private
# on include.
module ChatSessionLifecycle
  private

  CHAT_TURN_ENQUEUE_RETRY_DELAYS = [ 0.05, 0.2 ].freeze
  BRANCH_TITLE_SUFFIX = " (branch)".freeze

  def create_chat_session
    text = message_text
    repository = repository_from_params
    content = message_content(text) if text.present?
    return if performed?

    chat_session = nil
    user_message = nil

    ApplicationRecord.transaction do
      chat_session = ChatSession.create!(
        user: Current.user,
        repository: repository,
        title: nil,
        last_message_at: text.present? ? Time.current : nil
      )
      if text.present?
        user_message = chat_session.messages.create!(role: "user", content: content)
        chat_session.pin_chat_provider!
      end
    end

    enqueue_chat_title(chat_session, user_message) if user_message
    enqueue_chat_turn(chat_session, user_message) if user_message
    chat_session
  end

  def enqueue_chat_title(chat_session, user_message)
    ChatTitleJob.perform_later(chat_session.id, user_message.id)
  end

  def first_user_message(chat_session)
    chat_session.messages.where(role: "user").order(:created_at, :id).first
  end

  def enqueue_chat_turn(chat_session, user_message)
    retry_delays = CHAT_TURN_ENQUEUE_RETRY_DELAYS.dup

    begin
      ChatTurnJob.perform_later(chat_session.id, user_message.id)
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
      raise unless transient_chat_lock_error?(e) && retry_delays.any?

      delay = retry_delays.shift
      Rails.logger.warn("Retrying ChatTurnJob enqueue after transient database lock: #{e.class}: #{e.message}")
      sleep(delay) if delay.positive?
      retry
    end
  end

  def find_chat_session
    Current.user.chat_sessions.find(params[:id])
  end

  # Rename enforces ChatSession::TITLE_MAX_LENGTH (in characters,
  # matching the model validation), so a branch of a max-length
  # title must clamp the base before appending the suffix instead
  # of overflowing it.
  def branch_chat_title(source_chat)
    base = source_chat.title.presence ||
      ChatSession.fallback_title_for(source_chat.repository).presence ||
      "New chat"
    max_base_length = ChatSession::TITLE_MAX_LENGTH - BRANCH_TITLE_SUFFIX.length
    base = base.truncate(max_base_length, omission: "…") if base.length > max_base_length
    "#{base}#{BRANCH_TITLE_SUFFIX}"
  end

  def find_branch_source_chat_session
    chat_session = ChatSession.find(params[:id])
    return chat_session if chat_session.user_id == Current.user.id

    render_error("forbidden", "You cannot branch this chat.", status: :forbidden)
    nil
  end

  def branch_chat_messages!(source_chat, branched_chat)
    rows = source_chat.messages.order(:created_at, :id).map do |message|
      message.attributes.slice(
        "role",
        "content",
        "tool_name",
        "tool_use_id",
        "created_at",
        "updated_at"
      ).merge(
        "chat_session_id" => branched_chat.id,
        "proposal_id" => nil,
        "pending_action_id" => nil
      )
    end
    ChatMessage.insert_all!(rows) if rows.any?
  end
end
