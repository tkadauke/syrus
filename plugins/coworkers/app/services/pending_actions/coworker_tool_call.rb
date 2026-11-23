module PendingActions
  # Compatibility action key for coworker approval requests created before the
  # shared authorization executor became actor-neutral.
  class CoworkerToolCall < Syrus::Host::PendingActionAuthorizedToolCall
    action_key "coworker_tool_call"

    # This card and the ones coworker tools register under their own names.
    # The spawn limiter and the approval inbox count them all.
    def self.family_action_keys
      [ action_key, PendingActions::SpawnCoworkerChat.action_key, PendingActions::SpawnSyrusChat.action_key ]
    end

    def presentation_label = "Approve coworker action"
  end
end
