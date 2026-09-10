class AddLocalToolCallToChatShellCommands < ActiveRecord::Migration[8.1]
  # Local Mode `!` commands dispatch through LocalToolCall (the reverse-tunnel
  # run_command call) instead of SpawnedProcess, so cancellation needs its own
  # reference alongside the existing spawned_process_id (the chat shell-command cancellation feature).
  def change
    add_reference :chat_shell_commands, :local_tool_call, null: true, index: true unless column_exists?(:chat_shell_commands, :local_tool_call_id)
  end
end
