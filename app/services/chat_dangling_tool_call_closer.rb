require "set"

class ChatDanglingToolCallCloser
  # Why a tool call was closed without a real result, and whether that is
  # ordinary bookkeeping or evidence the turn broke.
  #
  # Callers name a reason rather than passing a sentence, for two reasons.
  # First, the prose lives here once: two callers used to build it by
  # interpolating their own constant
  # ("#{FAILED_MESSAGE.delete_suffix('.')} before this tool returned."), so the
  # exact text a reader saw depended on a variable several files away. Second,
  # the stored row now carries `benign_cleanup`, and the transcript renderer
  # suppresses on that flag instead of matching the sentence.
  #
  # That matching is what kept this bug alive. The renderer held a regex of
  # English it expected, so every new closing path needed the regex taught a
  # new sentence, and a reworded constant would have silently flooded chat with
  # failed-looking tool cards -- while both sides' tests passed, because they
  # hardcoded the same literals. Adding a reason here now cannot do that.
  Reason = Data.define(:key, :message, :benign)

  REASONS = [
    Reason.new(key: "turn_ended", message: "Agent turn ended before this tool returned.", benign: true),
    Reason.new(key: "operator_cancelled", message: "Cancelled by operator before this tool returned.", benign: true),
    Reason.new(key: "turn_failed", message: "Agent turn failed before this tool returned.", benign: false)
  ].index_by(&:key).freeze

  DEFAULT_REASON = "turn_ended"
  DEFAULT_MESSAGE = REASONS.fetch(DEFAULT_REASON).message

  def self.close!(...)
    new(...).close!
  end

  def self.reason_for(key)
    REASONS.fetch(key.to_s) do
      raise ArgumentError, "unknown dangling tool call reason #{key.inspect}; expected one of #{REASONS.keys.join(', ')}"
    end
  end

  def initialize(chat_session:, reason: DEFAULT_REASON)
    @chat_session = chat_session
    @reason = self.class.reason_for(reason)
  end

  def close!
    tool_uses = tool_uses_after_latest_user.to_a
    return 0 if tool_uses.empty?

    answered_ids = Set.new(
      messages_after_latest_user
        .where(role: "tool_result", tool_use_id: tool_uses.filter_map(&:tool_use_id))
        .pluck(:tool_use_id)
        .map(&:to_s)
    )

    tool_uses.sum do |tool_use|
      next 0 if tool_use.tool_use_id.present? && answered_ids.include?(tool_use.tool_use_id.to_s)

      @chat_session.messages.create!(
        role: "tool_result",
        tool_name: tool_use.tool_name,
        tool_use_id: tool_use.tool_use_id,
        content: {
          "type" => "tool_result",
          "tool_use_id" => tool_use.tool_use_id.to_s,
          "content" => [ { "type" => "text", "text" => @reason.message } ],
          # is_error stays true even for a benign close: the agent has to see
          # that the tool never returned, or a resumed turn would read the
          # cleanup as a real result. benign_cleanup is a separate,
          # presentation-only fact -- "this is bookkeeping, not a failure the
          # reader needs to see" -- which is why it is its own key rather than
          # a softer is_error.
          "is_error" => true,
          "cleanup_reason" => @reason.key,
          "benign_cleanup" => @reason.benign
        }
      )
      1
    end
  end

  private

  def tool_uses_after_latest_user
    messages_after_latest_user.where(role: "tool_use").order(:created_at, :id)
  end

  def messages_after_latest_user
    return @messages_after_latest_user if defined?(@messages_after_latest_user)

    latest_user = @chat_session.messages.where(role: "user").order(:created_at, :id).last
    scope = @chat_session.messages
    @messages_after_latest_user = if latest_user
      scope.where(
        "created_at > ? OR (created_at = ? AND id > ?)",
        latest_user.created_at,
        latest_user.created_at,
        latest_user.id
      )
    else
      scope.none
    end
  end
end
