class EnablePersistentMcpSidecarForExistingHiddenFlag < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE features
      SET enabled = TRUE,
          default_enabled = TRUE,
          updated_at = CURRENT_TIMESTAMP
      WHERE slug = 'persistent_mcp_sidecar'
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE features
      SET enabled = FALSE,
          default_enabled = FALSE,
          updated_at = CURRENT_TIMESTAMP
      WHERE slug = 'persistent_mcp_sidecar'
    SQL
  end
end
