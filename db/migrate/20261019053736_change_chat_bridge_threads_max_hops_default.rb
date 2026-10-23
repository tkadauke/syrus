class ChangeChatBridgeThreadsMaxHopsDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :chat_bridge_threads, :max_hops, from: 6, to: 100
  end
end
