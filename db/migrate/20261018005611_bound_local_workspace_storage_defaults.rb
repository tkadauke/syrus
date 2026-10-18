class BoundLocalWorkspaceStorageDefaults < ActiveRecord::Migration[8.1]
  def up
    change_column_default :app_settings, :prepared_layer_cache_gb, from: 100, to: 10
    change_column_default :app_settings, :chat_coding_workspace_budget_mb, from: 0, to: 10_240
  end

  def down
    change_column_default :app_settings, :prepared_layer_cache_gb, from: 10, to: 100
    change_column_default :app_settings, :chat_coding_workspace_budget_mb, from: 10_240, to: 0
  end
end
