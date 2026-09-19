class ScopeLandedCommitShaUniquenessToLandable < ActiveRecord::Migration[8.1]
  def up
    if index_exists?(:landed_commits, :sha, name: "index_landed_commits_on_sha")
      remove_index :landed_commits, name: "index_landed_commits_on_sha"
    end

    unless index_exists?(
      :landed_commits,
      [ :sha, :landable_type, :landable_id ],
      unique: true,
      name: "index_landed_commits_on_sha_and_landable"
    )
      add_index :landed_commits,
        [ :sha, :landable_type, :landable_id ],
        unique: true,
        name: "index_landed_commits_on_sha_and_landable"
    end
  end

  def down
    if index_exists?(
      :landed_commits,
      [ :sha, :landable_type, :landable_id ],
      name: "index_landed_commits_on_sha_and_landable"
    )
      remove_index :landed_commits, name: "index_landed_commits_on_sha_and_landable"
    end

    unless index_exists?(:landed_commits, :sha, name: "index_landed_commits_on_sha")
      add_index :landed_commits, :sha, unique: true, name: "index_landed_commits_on_sha"
    end
  end
end
