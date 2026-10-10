class AddMergeTrainMultisectSectionWidthToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :merge_train_multisect_section_width, :integer, if_not_exists: true
  end
end
