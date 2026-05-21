module ChatMessageGrouper
  module_function

  # Wrap a single tool_use message in the same shape the initial-render
  # grouper produces, so a Turbo Stream append of one message can
  # reuse the tool_call_group partial.
  def single_call_group(message, repository: nil)
    tool, detail = tool_signature(message, repository: repository)
    { type: :tool_group, tool: tool, calls: [ { message: message, detail: detail } ] }
  end

  # Walks a chronological array of ChatMessage records and returns a
  # flat list of "items" for the chat view. Most messages pass through
  # as `{ type: :message, message: <ChatMessage> }`; consecutive
  # tool_use messages of the same tool_name collapse into a single
  # `{ type: :tool_group, tool: "Read", calls: [...] }`. Each call
  # carries its own use message and (optionally) the result that
  # immediately followed it. tool_result messages don't appear as
  # standalone items — they're attached to the preceding tool_use
  # call's `:result`. tool_use messages that carry a proposal stay
  # as passthroughs so the proposal card keeps its dedicated layout.
  def group(messages, repository: nil)
    items = []
    current_group = nil

    messages.each do |message|
      if groupable_tool_use?(message)
        tool, detail = tool_signature(message, repository: repository)
        call = { message: message, detail: detail }

        if current_group && current_group[:tool] == tool
          current_group[:calls] << call
        else
          current_group = { type: :tool_group, tool: tool, calls: [ call ] }
          items << current_group
        end
      elsif groupable_tool_result?(message)
        if current_group && current_group[:calls].any? && current_group[:calls].last[:result].nil?
          current_group[:calls].last[:result] = message
        else
          items << { type: :message, message: message }
          current_group = nil
        end
      else
        current_group = nil
        items << { type: :message, message: message }
      end
    end

    items
  end

  def groupable_tool_use?(message)
    message.role == "tool_use" && message.tool_name.present? && message.proposal_id.blank?
  end

  def groupable_tool_result?(message)
    message.role == "tool_result" && message.proposal_id.blank?
  end

  # Returns [display_tool_name, primary_detail] for a tool_use
  # message. The detail is computed by AgentEventAbbreviator at
  # render time off the raw tool name and content["input"], and the
  # display name is the abbreviator's human-readable label (which
  # strips the "mcp__<server>__" prefix MCP tools come over as).
  def tool_signature(message, repository: nil)
    raw_name = message.tool_name.to_s
    input = message.content.is_a?(Hash) ? message.content["input"] : nil
    [
      AgentEventAbbreviator.tool_label(raw_name),
      AgentEventAbbreviator.tool_detail(
        raw_name,
        input || {},
        path_roots: path_roots_for(message, repository)
      ).to_s
    ]
  end

  def path_roots_for(message, repository)
    chat_session = message.chat_session
    repository ||= chat_session&.repository
    return [] unless chat_session && repository

    [ ChatWorkspace.repo_path_for(chat_session, repository).to_s ]
  end
end
