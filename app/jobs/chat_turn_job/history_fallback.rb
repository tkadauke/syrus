class ChatTurnJob
  # Chat-history fallback rendering extracted from ChatTurnJob: turning recent
  # persisted chat messages into a compact text transcript that keeps the agent
  # coherent when provider-side session resume is missing/stale/rejected. Mixed in
  # via include, so it reads the same @chat/@user_message state and the
  # HISTORY_FALLBACK_* byte/entry limits through the class ancestry.
  module HistoryFallback
    def chat_history_fallback
      messages = @chat.messages
                      .includes(:proposal, :pending_action)
                      .where.not(id: @user_message.id)
                      .order(created_at: :desc, id: :desc)
                      .limit(HISTORY_FALLBACK_MESSAGE_LIMIT)
                      .to_a
                      .reverse
      entries = messages.filter_map { |message| chat_history_entry(message) }
      return nil if entries.empty?

      body = bounded_history_entries(entries)
      return nil if body.blank?

      <<~TEXT.strip
        Recent persisted chat context fallback:
        Provider resume should still be attempted, but this compact transcript is included so you can continue coherently if provider-side session history is missing, stale, incomplete, or rejected.

        #{body}
      TEXT
    end

    def chat_history_entry(message)
      case message.role
      when "user", "assistant"
        text = content_text(message)
        lines = [ "#{message.role}: #{bounded_history_text(text)}" ]
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
      selected = []
      total_bytes = 0

      entries.reverse_each do |entry|
        next if entry.blank?

        separator_bytes = selected.empty? ? 0 : 2
        candidate_bytes = entry.bytesize + separator_bytes
        break if total_bytes + candidate_bytes > HISTORY_FALLBACK_MAX_BYTES

        selected << entry
        total_bytes += candidate_bytes
      end

      selected.reverse.join("\n\n")
    end

    def content_text(message)
      return message.content["text"].to_s if message.content.is_a?(Hash)

      message.content.to_s
    end

    def bounded_history_text(text, max_bytes = HISTORY_FALLBACK_ENTRY_MAX_BYTES)
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
      return true if source == ChatPendingActionOutcomeNotification::SOURCE
      return true if content["supervisor_event"].present?
      text.match?(/\AProposal .*(confirmed|rejected|withdrawn|created|materialized)/i) ||
        text.match?(/\A(Pending action (confirmed|rejected|dismissed)|Cancelled by operator|Agent turn failed|Agent turn completed|MCP unavailable|Codex resume)/i)
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
      result = content["content"] || content["result"]
      text = tool_result_text(result)
      tool_name = message.tool_name.presence || "tool"
      status = content["is_error"] ? "error" : "ok"

      if text.present?
        "tool_result: #{tool_name} #{status}: #{bounded_history_text(text, HISTORY_FALLBACK_TOOL_RESULT_MAX_BYTES)}"
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
end
