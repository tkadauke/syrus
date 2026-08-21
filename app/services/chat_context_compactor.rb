class ChatContextCompactor
  MIN_MESSAGES = 120
  KEEP_RECENT_MESSAGES = 40
  MAX_SUMMARY_BYTES = 18.kilobytes
  MAX_RENDERED_EVENTS = 80
  ENTRY_MAX_BYTES = 500
  TOOL_RESULT_MAX_BYTES = 350
  SUMMARY_VERSION = 1

  ContextMessage = Data.define(:id, :role, :content, :created_at, :tool_name, :tool_use_id) do
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
  end

  class << self
    def maybe_compact!(chat_session)
      new(chat_session).maybe_compact!
    end

    def context_messages_for(chat_session)
      new(chat_session).context_messages
    end

    def enabled_for?(chat_session)
      new(chat_session).enabled_for_chat?
    end
  end

  def initialize(chat_session)
    @chat_session = chat_session
  end

  def maybe_compact!
    return unless enabled_for_chat?

    cutoff_id = compaction_cutoff_message_id
    return unless cutoff_id

    latest = latest_checkpoint
    return latest if latest&.compacted_through_message_id.to_i >= cutoff_id

    compacted = messages_scope
                  .where("id > ?", latest&.compacted_through_message_id.to_i || 0)
                  .where("id <= ?", cutoff_id)
                  .order(:id)
                  .to_a
    return if compacted.empty?

    @chat_session.context_checkpoints.create!(
      compacted_through_message_id: cutoff_id,
      source_message_count: latest&.source_message_count.to_i + compacted.size,
      summary_version: SUMMARY_VERSION,
      summary: build_summary(compacted, previous: latest)
    )
  end

  def context_messages
    return messages_for_full_replay unless enabled_for_chat?

    checkpoint = latest_checkpoint
    return messages_for_full_replay unless checkpoint

    [ checkpoint_message(checkpoint), *messages_after(checkpoint) ]
  end

  def enabled_for_chat?
    Feature.chat_context_compaction_enabled? && @chat_session.supervisor_chat?
  end

  private

  def messages_scope
    scope = ChatMessage.where(chat_session_id: @chat_session.id)
    return scope unless mysql_adapter?

    scope.from(Arel.sql("#{ChatMessage.quoted_table_name} FORCE INDEX (index_chat_messages_on_session_id_and_id)"))
  end

  def latest_checkpoint
    @chat_session.context_checkpoints.latest_first.first
  end

  def mysql_adapter?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
  end

  def compaction_cutoff_message_id
    newest_ids = messages_scope.reselect(:id).order(id: :desc).limit(MIN_MESSAGES).pluck(:id)
    return if newest_ids.size < MIN_MESSAGES

    newest_ids[KEEP_RECENT_MESSAGES]
  end

  def messages_for_full_replay
    relation = messages_scope.order(:id)
    return relation unless Feature.chat_context_compaction_enabled?

    exclude_current_unanswered_user(relation).to_a
  end

  def messages_after(checkpoint)
    relation = messages_scope.where("id > ?", checkpoint.compacted_through_message_id).order(:id)
    exclude_current_unanswered_user(relation).to_a
  end

  def exclude_current_unanswered_user(relation)
    latest = messages_scope.order(id: :desc).limit(1).first
    return relation unless latest&.role == "user"

    relation.where.not(id: latest.id)
  end

  def checkpoint_message(checkpoint)
    ContextMessage.new(
      id: 0,
      role: "assistant",
      content: [
        {
          "type" => "text",
          "text" => <<~TEXT.strip
            Prior durable chat context summary through ChatMessage ##{checkpoint.compacted_through_message_id}:

            #{checkpoint.summary}

            The full transcript remains stored in Syrus. Use chat/search/admin tools if exact older details are needed.
          TEXT
        }
      ],
      created_at: checkpoint.created_at,
      tool_name: nil,
      tool_use_id: nil
    )
  end

  def build_summary(messages, previous:)
    counts = messages.map(&:role).tally
    rendered = messages.last(MAX_RENDERED_EVENTS).filter_map { |message| render_message(message) }
    text = [
      "Compacted #{messages.size} older messages for #{@chat_session.title.presence || "Chat #{@chat_session.id}"}.",
      role_counts_line(counts),
      previous_summary(previous),
      "Recent compacted events:",
      *rendered
    ].compact.join("\n")

    truncate(text, MAX_SUMMARY_BYTES)
  end

  def role_counts_line(counts)
    "Role counts: " + %w[user assistant tool_use tool_result system].filter_map { |role|
      count = counts[role]
      "#{role}=#{count}" if count.to_i.positive?
    }.join(", ")
  end

  def previous_summary(previous)
    return unless previous

    "Previous checkpoint: through ChatMessage ##{previous.compacted_through_message_id}; summary was carried forward."
  end

  def render_message(message)
    case message.role
    when "user", "assistant", "system"
      text = content_text(message)
      return if text.blank? || ignorable_system_text?(message, text)

      "#{message.role} ##{message.id}: #{truncate(text, ENTRY_MAX_BYTES)}"
    when "tool_use"
      "tool_use ##{message.id}: #{message.tool_name.presence || tool_name_from_content(message)} #{compact_tool_input(message)}".strip
    when "tool_result"
      text = tool_result_text(message)
      status = message.content.is_a?(Hash) && message.content["is_error"] == true ? "error" : "ok"
      "tool_result ##{message.id}: #{message.tool_name.presence || "tool"} #{status} #{truncate(text, TOOL_RESULT_MAX_BYTES)}".strip
    end
  end

  def content_text(message)
    if message.content.is_a?(Array)
      message.content.filter_map { |block| block["text"].to_s if block.is_a?(Hash) && block["type"] == "text" }.join("\n")
    elsif message.content.is_a?(Hash)
      message.content["text"].to_s
    else
      message.content.to_s
    end
  end

  def ignorable_system_text?(message, text)
    return false unless message.role == "system"

    text.start_with?("[codex result]", "[chat_session]")
  end

  def tool_name_from_content(message)
    message.content.is_a?(Hash) ? message.content["name"].to_s : "tool"
  end

  def compact_tool_input(message)
    input = message.content.is_a?(Hash) ? message.content["input"] : nil
    return "" unless input.is_a?(Hash)

    keys = %w[status command file_path path repository_id job_id epic_id workflow_id run_id id title]
    selected = input.slice(*keys).compact
    selected.present? ? truncate(selected.to_json, ENTRY_MAX_BYTES) : ""
  end

  def tool_result_text(message)
    return "" unless message.content.is_a?(Hash)

    result = message.content["content"] || message.content["result"]
    case result
    when Array
      result.filter_map { |item| item["text"].to_s if item.is_a?(Hash) && item["type"] == "text" }.join("\n")
    when Hash
      result.slice("status", "message", "error", "slug", "id", "title").compact.to_json
    else
      result.to_s
    end
  end

  def truncate(text, max_bytes)
    value = text.to_s.strip
    return value if value.bytesize <= max_bytes

    omitted = value.bytesize - max_bytes
    "#{value.safe_byteslice(0, max_bytes).strip}\n...[truncated #{omitted} bytes]"
  end
end
