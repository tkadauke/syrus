class AddFeedbackPolicyToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :feedback_policy, :string, default: "auto" unless column_exists?(:repositories, :feedback_policy)
    execute "UPDATE repositories SET feedback_policy = 'auto' WHERE feedback_policy IS NULL"
    change_column_null :repositories, :feedback_policy, false
  end

  def down
    remove_column :repositories, :feedback_policy if column_exists?(:repositories, :feedback_policy)
  end
end
