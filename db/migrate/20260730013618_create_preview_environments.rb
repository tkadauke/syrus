class CreatePreviewEnvironments < ActiveRecord::Migration[8.1]
  def up
    create_table :preview_environments, if_not_exists: true do |t|
      t.references :job, null: false, foreign_key: true
      t.string :state, null: false, default: "starting"
      t.integer :port
      t.string :internal_host
      t.string :workspace_path
      t.datetime :expires_at
      t.datetime :last_activity_at
      t.text :error_message
      t.timestamps
    end

    unless index_exists?(:preview_environments, :job_id, name: "index_preview_environments_on_job_id_active",
                                                          where: "state IN ('starting','seeding','running','stopping')")
      add_index :preview_environments, :job_id,
                name: "index_preview_environments_on_job_id_active",
                where: "state IN ('starting','seeding','running','stopping')"
    end

    unless index_exists?(:preview_environments, :state)
      add_index :preview_environments, :state
    end

    unless index_exists?(:preview_environments, :expires_at)
      add_index :preview_environments, :expires_at
    end
  end

  def down
    drop_table :preview_environments, if_exists: true
  end
end
