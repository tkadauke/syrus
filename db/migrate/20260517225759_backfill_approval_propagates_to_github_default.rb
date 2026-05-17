class BackfillApprovalPropagatesToGithubDefault < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:repositories, :approval_propagates_to_github)
      add_column :repositories, :approval_propagates_to_github, :boolean, default: true
    end

    change_column_default :repositories, :approval_propagates_to_github, true
    execute <<~SQL.squish
      UPDATE repositories
      SET approval_propagates_to_github = #{connection.quoted_true}
      WHERE approval_propagates_to_github IS NULL
    SQL
  end

  def down
    return unless column_exists?(:repositories, :approval_propagates_to_github)

    change_column_default :repositories, :approval_propagates_to_github, nil
  end
end
