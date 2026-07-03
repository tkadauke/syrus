class AddReviewPolicyToRepositories < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:repositories, :review_policy)
      add_column :repositories, :review_policy, :string, null: false, default: "self"
    end
  end

  def down
    remove_column :repositories, :review_policy if column_exists?(:repositories, :review_policy)
  end
end
