class ChatHistoryTranscriptRenderer
  COMPACT_MESSAGE_LIMIT = 24
  COMPACT_MAX_BYTES = 12_000
  COMPACT_ENTRY_MAX_BYTES = 1_000
  COMPACT_TOOL_RESULT_MAX_BYTES = 400

  RECOVERY_MESSAGE_LIMIT = 240
  RECOVERY_MAX_BYTES = 120_000
  RECOVERY_ENTRY_MAX_BYTES = 4_000
  RECOVERY_TOOL_RESULT_MAX_BYTES = 1_500

  def initialize(chat_session:, current_message: nil, message_limit:, max_bytes:, entry_max_bytes:, tool_result_max_bytes:, preserve_first_entry: false)
    @chat = chat_session
    @current_message = current_message
    @message_limit = message_limit
    @max_bytes = max_bytes
    @entry_max_bytes = entry_max_bytes
    @tool_result_max_bytes = tool_result_max_bytes
    @preserve_first_entry = preserve_first_entry
  end

  def self.compact_fallback(chat_session:, current_message:)
    new(
      chat_session: chat_session,
      current_message: current_message,
      message_limit: COMPACT_MESSAGE_LIMIT,
      max_bytes: COMPACT_MAX_BYTES,
      entry_max_bytes: COMPACT_ENTRY_MAX_BYTES,
      tool_result_max_bytes: COMPACT_TOOL_RESULT_MAX_BYTES
    ).compact_fallback
  end

  def self.resume_recovery(chat_session:)
    new(
      chat_session: chat_session,
      message_limit: RECOVERY_MESSAGE_LIMIT,
      max_bytes: RECOVERY_MAX_BYTES,
      entry_max_bytes: RECOVERY_ENTRY_MAX_BYTES,
      tool_result_max_bytes: RECOVERY_TOOL_RESULT_MAX_BYTES,
      preserve_first_entry: true
    ).resume_recovery
  end

  def compact_fallback
    body = render_entries(compact_messages)
    return nil if body.blank?

    <<~TEXT.strip
      Recent persisted chat context fallback:
      Provider resume should still be attempted, but this compact transcript is included so you can continue coherently if provider-side session history is missing, stale, incomplete, or rejected.

      #{body}
    TEXT
  end

  def resume_recovery
    body = render_entries(recovery_messages)
    return nil if body.blank?

    <<~TEXT.strip
      Persisted chat context recovered after provider resume failed:
      Provider resume was unavailable, so this fresh session is being grounded in the database transcript. The first user message is preserved, followed by as much recent persisted history as fits the larger recovery budget.

      #{body}
    TEXT
  end

  private

  attr_reader :chat, :current_message, :message_limit, :max_bytes, :entry_max_bytes, :tool_result_max_bytes

  def compact_messages
    relation = base_relation
    relation = relation.where.not(id: current_message.id) if current_message
    relation.order(created_at: :desc, id: :desc).limit(message_limit).to_a.reverse
  end

  def recovery_messages
    first_user = base_relation.where(role: "user").order(:created_at, :id).first
    recent = base_relation.order(created_at: :desc, id: :desc).limit(message_limit).to_a.reverse

    ([ first_user ] + recent).compact.uniq(&:id)
  end

  def base_relation
    chat.messages.active.includes(:proposal, :pending_action, :sender_user)
  end

  def render_entries(messages)
    entries = messages.filter_map { |message| chat_history_entry(message) }
    return nil if entries.empty?

    bounded_history_entries(entries)
  end

  def chat_history_entry(message)
    case message.role
    when "user", "assistant"
      text = content_text(message)
      prefix = user_message_prefix(message)
      lines = [ "#{message.role}: #{prefix}#{bounded_history_text(text)}" ]
      lines << proposal_summary(message.proposal) if message.proposal
      lines << pending_action_summary(message.pending_action) if message.pending_action
      lines.join("\n")
    when "system"
      text = content_text(message)
      return nil unless important_system_message?(message, text)

      "system: #{bounded_history_text(text)}"
    when "tool_use"
      tool_name = message.tool_name.presence || "tool"
      content = message.content.is_a?(Hash) ? message.content : {}
      summary = compact_tool_input(content["input"])
      [ "tool_use: #{tool_name}", summary.presence ].compact.join(" ")
    when "tool_result"
      tool_result_summary(message)
    end
  end

  def bounded_history_entries(entries)
    return bounded_recent_entries(entries) unless @preserve_first_entry

    selected = []
    total_bytes = 0
    first_entry = entries.first
    recent_entries = entries.drop(1)

    recent_entries.reverse_each do |entry|
      next if entry.blank?

      separator_bytes = selected.empty? ? 0 : 2
      candidate_bytes = entry.bytesize + separator_bytes
      break if total_bytes + candidate_bytes > max_bytes

      selected << entry
      total_bytes += candidate_bytes
    end

    selected.reverse!
    return selected.join("\n\n") unless first_entry.present?
    return first_entry if selected.empty?

    first_with_separator_bytes = first_entry.bytesize + 2
    while selected.any? && total_bytes + first_with_separator_bytes > max_bytes
      removed = selected.shift
      total_bytes -= removed.bytesize
      total_bytes -= 2 if selected.any?
    end

    ([ first_entry ] + selected).join("\n\n")
  end

  def bounded_recent_entries(entries)
    selected = []
    total_bytes = 0

    entries.reverse_each do |entry|
      next if entry.blank?

      separator_bytes = selected.empty? ? 0 : 2
      candidate_bytes = entry.bytesize + separator_bytes
      break if total_bytes + candidate_bytes > max_bytes

      selected << entry
      total_bytes += candidate_bytes
    end

    selected.reverse.join("\n\n")
  end

  def content_text(message)
    return message.content.to_s unless message.content.is_a?(Hash)

    message.content["text"].presence || message.content["internal_prompt"].to_s
  end

  def bounded_history_text(text, max_bytes = entry_max_bytes)
    value = text.to_s.strip
    return "" if value.blank?
    return value if value.bytesize <= max_bytes

    "#{value.safe_byteslice(0, max_bytes).strip} ...[truncated]"
  end

  def important_system_message?(message, text)
    content = message.content.is_a?(Hash) ? message.content : {}
    source = content["source"].to_s
    return true if source == "proposal_notification"
    return true if source == "grader_report"
    return true if content["scoped_event"].present?

    text.match?(/\AProposal .*(confirmed|rejected|withdrawn|created|materialized)/i) ||
      text.match?(/\A(Cancelled by operator|Agent turn failed|Agent turn completed|MCP unavailable|Codex resume)/i)
  end

  def multi_participant?
    @multi_participant ||= chat.participants.count > 1
  end

  def user_message_prefix(message)
    return "" unless message.role == "user" && multi_participant?

    sender = message.sender_user
    return "" unless sender

    name = sender.first_name.presence || sender.email_address.split("@").first
    "[#{name}]: "
  end

  def proposal_summary(proposal)
    return nil unless proposal

    materialized = proposal.materialized_label.presence
    parts = [
      "proposal=#{proposal.slug}",
      "state=#{proposal.state}",
      "kind=#{proposal.kind}",
      "title=#{proposal.title.inspect}"
    ]
    parts << "materialized=#{materialized}" if materialized
    "proposal_summary: #{parts.join(', ')}"
  end

  def pending_action_summary(action)
    return nil unless action

    "pending_action: #{action.action.presence || action.action_type} state=#{action.state}"
  end

  def compact_tool_input(input)
    case input
    when Hash
      keys = %w[status command file_path path repository_id job_id epic_id slug title]
      input.slice(*keys).compact.to_json
    else
      nil
    end
  end

  def tool_result_summary(message)
    content = message.content.is_a?(Hash) ? message.content : {}
    result = content["content"].presence || content["result"]
    text = tool_result_text(result)
    tool_name = message.tool_name.presence || "tool"
    status = content["is_error"] ? "error" : "ok"

    if text.present?
      "tool_result: #{tool_name} #{status}: #{bounded_history_text(text, tool_result_max_bytes)}"
    else
      "tool_result: #{tool_name} #{status}"
    end
  end

  def tool_result_text(result)
    case result
    when Array
      result.filter_map { |item| item["text"].to_s if item.is_a?(Hash) && item["type"] == "text" }.join("\n").presence
    when Hash
      result.slice("status", "message", "error", "slug", "id", "title").compact.to_json
    when String
      result
    end
  end
end
