class AddErrorReasonToPreviewEnvironments < ActiveRecord::Migration[8.1]
  def change
    add_column :preview_environments, :error_reason, :string unless column_exists?(:preview_environments, :error_reason)
  end
end
