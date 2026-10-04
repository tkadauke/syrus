class AddCurrentTurnMessageIdToChatSessions < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:chat_sessions, :current_turn_message_id)

    # The message a turn is running for. `turn_in_flight` only records *that*
    # a turn is running, and the message driving it used to be inferred as the
    # last `user` message -- which is wrong for any turn a non-user message
    # starts, such as a proposal confirmation. MCP invocation tokens are scoped
    # to a turn's message, so that inference rejected those turns' own tokens.
    add_column :chat_sessions, :current_turn_message_id, :bigint
  end
end
