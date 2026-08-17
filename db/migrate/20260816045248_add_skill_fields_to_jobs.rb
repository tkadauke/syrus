class AddSkillFieldsToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :skill_name, :string unless column_exists?(:jobs, :skill_name)
    add_column :jobs, :skill_args, :json unless column_exists?(:jobs, :skill_args)
  end
end
