class RenamePreviewToolsPluginRecord < ActiveRecord::Migration[8.1]
  # `plugin_records` is keyed by plugin name, so renaming preview_tools to
  # mockups would otherwise orphan the old row and give the plugin a fresh one
  # at its default state -- silently re-enabling it for anyone who had turned
  # it off, and losing any config they had set.
  def up
    move_record("preview_tools", "mockups")
  end

  def down
    move_record("mockups", "preview_tools")
  end

  private

  def move_record(old_name, new_name)
    return unless table_exists?(:plugin_records)

    old_record = PluginRecord.find_by(name: old_name)
    return unless old_record

    new_record = PluginRecord.find_by(name: new_name)
    if new_record
      new_record.update!(
        enabled: old_record.enabled,
        default_enabled: old_record.default_enabled,
        disableable: old_record.disableable,
        config: new_record.config.to_h.deep_merge(old_record.config.to_h)
      )
      old_record.destroy!
    else
      old_record.update!(name: new_name)
    end
  end
end
