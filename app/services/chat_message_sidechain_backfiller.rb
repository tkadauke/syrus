# Claude Code doesn't stream subagent (Task/Agent tool) turns live -- they
# only land in sidecar `subagents/agent-<id>.jsonl` files once the turn
# finishes (see ChatProviders::Claude#session_capture). That means
# ChatTurnJob#record_agent_event has already created the ChatMessage rows
# for a turn, from the live stream, before any sidechain metadata exists.
# Once the post-turn transcript capture computes normalized_messages
# (ClaudeTranscript + ChatProviders::Base#normalized_messages_for, tagged
# with `sidechain`/`parent_tool_use_id`), this backfills the matching
# ChatMessage rows by tool_use_id so the tag survives on stored chat data.
class ChatMessageSidechainBackfiller
  def self.call(...)
    new(...).call
  end

  def initialize(chat_session:, normalized_messages:)
    @chat_session = chat_session
    @normalized_messages = Array(normalized_messages)
  end

  def call
    sidechain_parent_by_tool_use_id.each do |tool_use_id, parent_tool_use_id|
      @chat_session.messages
        .where(tool_use_id: tool_use_id)
        .where(sidechain: false)
        .update_all(sidechain: true, parent_tool_use_id: parent_tool_use_id)
    end
  end

  private

  def sidechain_parent_by_tool_use_id
    @normalized_messages.each_with_object({}) do |message, memo|
      next unless message.is_a?(Hash) && message["sidechain"] == true
      next unless %w[tool_use tool_result].include?(message["role"])

      tool_use_id = tool_use_id_for(message["content"])
      next if tool_use_id.blank?

      memo[tool_use_id.to_s] = message["parent_tool_use_id"]
    end
  end

  def tool_use_id_for(content)
    return nil unless content.is_a?(Hash)

    content[:id] || content["id"] || content[:tool_use_id] || content["tool_use_id"]
  end
end
