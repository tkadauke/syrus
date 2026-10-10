class AddMergeTrainMultisectSectionWidthToAppSettings < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:app_settings, :merge_train_multisect_section_width)
      add_column :app_settings, :merge_train_multisect_section_width, :integer, default: 4, null: false
    end
  end
end
