module PendingActions
  # Compatibility action key for coworker approval requests created before the
  # shared authorization executor became actor-neutral.
  class CoworkerToolCall < Syrus::Host::PendingActionsAuthorizedToolCall
    action_key "coworker_tool_call"

    def presentation_label = "Approve coworker action"
  end
end
