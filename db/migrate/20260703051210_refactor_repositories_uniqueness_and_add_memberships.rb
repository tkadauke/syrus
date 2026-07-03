class RefactorRepositoriesUniquenessAndAddMemberships < ActiveRecord::Migration[8.1]
  # Migration-local class so we bypass model validations during data backfills.
  class MigrationRepository < ActiveRecord::Base
    self.table_name = "repositories"
  end

  def up
    # 1. Create repository_memberships join table.
    create_table :repository_memberships, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: "owner"
      t.timestamps
    end
    unless index_exists?(:repository_memberships, [ :repository_id, :user_id ])
      add_index :repository_memberships, [ :repository_id, :user_id ], unique: true,
        name: "index_repository_memberships_on_repository_id_and_user_id"
    end

    # 2. Add upstream_repository_id FK column.
    unless column_exists?(:repositories, :upstream_repository_id)
      add_column :repositories, :upstream_repository_id, :bigint
    end
    unless index_exists?(:repositories, :upstream_repository_id)
      add_index :repositories, :upstream_repository_id,
        name: "index_repositories_on_upstream_repository_id"
    end

    # 3. Backfill one owner membership per existing repository.
    execute <<~SQL
      INSERT INTO repository_memberships (repository_id, user_id, role, created_at, updated_at)
      SELECT id, user_id, 'owner', created_at, updated_at
      FROM repositories
      WHERE user_id IS NOT NULL
    SQL

    # 4. Make user_id nullable — repositories are now globally unique, owned
    #    through the memberships table rather than the FK column.
    change_column_null :repositories, :user_id, true

    # 5. Replace per-user unique index with a global [owner, name] unique index.
    remove_index :repositories, name: "index_repositories_on_user_id_and_owner_and_name" if index_exists?(:repositories, [ :user_id, :owner, :name ])
    unless index_exists?(:repositories, [ :owner, :name ])
      add_index :repositories, [ :owner, :name ], unique: true,
        name: "index_repositories_on_owner_and_name"
    end

    # 6. Backfill upstream_repository_id: for each repo with upstream_owner/name
    #    set, find or create the upstream repository record and link it.
    MigrationRepository
      .where.not(upstream_owner: [ nil, "" ])
      .where.not(upstream_name: [ nil, "" ])
      .find_each do |repo|
        upstream = MigrationRepository.find_or_create_by!(
          owner: repo.upstream_owner,
          name: repo.upstream_name
        ) do |r|
          r.default_branch = repo.upstream_default_branch.presence || "main"
          r.trigger_label = "syrus"
          r.polling_enabled = false
        end
        repo.update_column(:upstream_repository_id, upstream.id)
      end

    # 7. Add FK constraint for upstream_repository_id.
    unless foreign_key_exists?(:repositories, :repositories, column: :upstream_repository_id)
      add_foreign_key :repositories, :repositories, column: :upstream_repository_id
    end
  end

  def down
    remove_foreign_key :repositories, column: :upstream_repository_id if foreign_key_exists?(:repositories, :repositories, column: :upstream_repository_id)

    remove_index :repositories, name: "index_repositories_on_owner_and_name" if index_exists?(:repositories, [ :owner, :name ])
    unless index_exists?(:repositories, [ :user_id, :owner, :name ])
      add_index :repositories, [ :user_id, :owner, :name ], unique: true,
        name: "index_repositories_on_user_id_and_owner_and_name"
    end

    change_column_null :repositories, :user_id, false

    remove_index :repositories, name: "index_repositories_on_upstream_repository_id" if index_exists?(:repositories, :upstream_repository_id)
    remove_column :repositories, :upstream_repository_id if column_exists?(:repositories, :upstream_repository_id)

    drop_table :repository_memberships, if_exists: true
  end
end
