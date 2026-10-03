class ChatTitleJob < ApplicationJob
  queue_as :low_priority_maintenance
  discard_on ActiveRecord::RecordNotFound

  class << self
    attr_accessor :agent_runner
  end

  def perform(chat_session_id, user_message_id = nil, message_text: nil)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    seed_source = message_text.nil? ? "message_id" : "message_text"
    chat_session = ChatSession.includes(:user, :attached_repositories).find(chat_session_id)
    chat_provider = chat_session.effective_chat_provider

    if real_title?(chat_session)
      record_outcome(
        chat_session: chat_session,
        user_message_id: user_message_id,
        seed_source: seed_source,
        provider: chat_provider,
        started_at: started_at,
        status: "skipped",
        title_write: "existing_title"
      )
      return
    end

    message_text ||= chat_session.messages.where(role: "user").find(user_message_id).content["text"]
    chat_provider = chat_session.pin_chat_provider!(broadcast: false)
    generated = ChatTitleGenerator.new(
      chat_session: chat_session,
      message_text: message_text,
      chat_provider: chat_provider,
      runner: self.class.agent_runner
    ).call

    if generated.success?
      outcome_chat, status, title_write = write_generated_title(chat_session.id, generated.title)
      record_outcome(
        chat_session: outcome_chat,
        user_message_id: user_message_id,
        seed_source: seed_source,
        provider: chat_provider,
        started_at: started_at,
        status: status,
        title_write: title_write
      )
    else
      outcome_chat, status, title_write = write_fallback_title(chat_session.id)
      record_outcome(
        chat_session: outcome_chat,
        user_message_id: user_message_id,
        seed_source: seed_source,
        provider: chat_provider,
        started_at: started_at,
        status: status,
        title_write: title_write,
        failure_reason: status == "failure" ? generated.error : nil,
        problem_code: status == "failure" ? generated.problem_code : nil
      )
    end
  end

  private

  def real_title?(chat_session)
    chat_session.title.present? && !chat_session.title_auto_fallback?
  end

  def write_generated_title(chat_session_id, title)
    write_title(chat_session_id) do |chat_session|
      chat_session.update!(title: title, title_auto_fallback: false)
      [ chat_session, "success", "generated" ]
    end
  end

  def write_fallback_title(chat_session_id)
    write_title(chat_session_id) do |chat_session|
      chat_session.update!(title: fallback_title(chat_session), title_auto_fallback: true)
      [ chat_session, "failure", "fallback" ]
    end
  end

  def write_title(chat_session_id)
    outcome = nil
    ChatSession.transaction do
      chat_session = ChatSession.lock.find(chat_session_id)
      outcome = if real_title?(chat_session)
        [ chat_session, "skipped", "existing_title" ]
      else
        yield chat_session
      end
    end
    outcome
  end

  def fallback_title(chat_session)
    ChatSession.fallback_title_for(chat_session.repository).presence || "New chat"
  end

  def record_outcome(chat_session:, user_message_id:, seed_source:, provider:, started_at:, status:, title_write:,
                     failure_reason: nil, problem_code: nil)
    OperationalLogging.ingest(
      level: status == "failure" ? "warn" : "info",
      source: "chat_title_job",
      message: "ChatTitleJob #{status} for chat #{chat_session.id}",
      context: {
        chat_session_id: chat_session.id,
        user_message_id: user_message_id,
        seed_source: seed_source,
        provider: provider,
        elapsed_ms: elapsed_ms(started_at),
        status: status,
        failure_reason: failure_reason,
        problem_code: problem_code,
        title_write: title_write,
        title_auto_fallback: chat_session.title_auto_fallback?
      }.compact
    )
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round(1)
  end
end
