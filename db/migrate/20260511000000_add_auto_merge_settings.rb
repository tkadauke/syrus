class AddAutoMergeSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :auto_merge_enabled, :boolean, default: false, null: false
  end
end
