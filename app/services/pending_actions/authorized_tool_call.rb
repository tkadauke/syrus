module PendingActions
  # Shared exact-invocation executor. The established implementation also
  # serves coworker compatibility requests while new actor surfaces use this
  # neutral action key.
  class AuthorizedToolCall < CoworkerToolCall
    action_key "authorized_tool_call"

    def presentation_label = "Approve agent action"
  end
end
