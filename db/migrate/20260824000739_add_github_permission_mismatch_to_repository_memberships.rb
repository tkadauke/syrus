class AddGithubPermissionMismatchToRepositoryMemberships < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:repository_memberships, :github_permission_mismatch_reason)
      add_column :repository_memberships, :github_permission_mismatch_reason, :string
    end

    unless column_exists?(:repository_memberships, :github_permission_mismatch_checked_at)
      add_column :repository_memberships, :github_permission_mismatch_checked_at, :datetime
    end
  end
end
