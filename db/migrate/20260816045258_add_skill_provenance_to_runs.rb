class AddSkillProvenanceToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :skill_source, :string unless column_exists?(:runs, :skill_source)
    add_column :runs, :skill_resolved_path, :string unless column_exists?(:runs, :skill_resolved_path)
    add_column :runs, :skill_resolved_class, :string unless column_exists?(:runs, :skill_resolved_class)
  end
end
