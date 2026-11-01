module AuthorizationContinuations
  class Payload
    def self.approved(checkpoint:, tool_result:)
      {
        "type" => "authorization_continuation",
        "outcome" => "approved",
        "checkpoint" => checkpoint.to_h.deep_stringify_keys,
        "tool_result" => tool_result
      }
    end

    def self.denied(checkpoint:, reason: nil)
      {
        "type" => "authorization_continuation",
        "outcome" => "denied",
        "checkpoint" => checkpoint.to_h.deep_stringify_keys,
        "denial" => {
          "code" => "authorization_denied",
          "reason" => reason.to_s.presence
        }.compact
      }
    end
  end
end
