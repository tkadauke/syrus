class AddSourceRefToJobs < ActiveRecord::Migration[8.1]
  # workflow-engine-v3 C4: cross-source identity.
  #
  # `external_ref` exists but is per-source and unqualified -- GitHub stores
  # the bare issue number, and lookups only work because they also scope by
  # input_source_id. One request can now enter through several doors (a GitHub
  # issue, PR intake, a chat proposal, a bug report), and "42" from two of them
  # is two different things.
  #
  # `source_ref` is the qualified form, e.g. "github:acme/widgets#42". Nullable
  # and unenforced: a Job that predates this, or arrives through a door with no
  # natural ref, simply has none.
  def up
    return if column_exists?(:jobs, :source_ref)

    add_column :jobs, :source_ref, :string
    add_index :jobs, :source_ref unless index_exists?(:jobs, :source_ref)
  end

  def down
    remove_index :jobs, :source_ref if index_exists?(:jobs, :source_ref)
    remove_column :jobs, :source_ref if column_exists?(:jobs, :source_ref)
  end
end
