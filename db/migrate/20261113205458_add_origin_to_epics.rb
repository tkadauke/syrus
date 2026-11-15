class AddOriginToEpics < ActiveRecord::Migration[8.1]
  def up
    add_column :epics, :origin, :string unless column_exists?(:epics, :origin)

    # Historical GitHub-shaped URLs are ambiguous because operator-created
    # Epics accepted the same field. Keep those operator-owned rather than
    # granting marker attachment without durable ingestion provenance.
    execute <<~SQL.squish
      UPDATE epics
      SET origin = CASE
        WHEN github_issue_url LIKE 'linear:issue:%' THEN 'linear_issue'
        ELSE 'operator'
      END
      WHERE origin IS NULL
    SQL

    change_column_default :epics, :origin, from: nil, to: "operator"
    change_column_null :epics, :origin, false
    add_index :epics, :origin unless index_exists?(:epics, :origin)
  end

  def down
    remove_index :epics, :origin if index_exists?(:epics, :origin)
    remove_column :epics, :origin if column_exists?(:epics, :origin)
  end
end
