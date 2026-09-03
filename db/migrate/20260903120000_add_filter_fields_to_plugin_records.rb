class AddFilterFieldsToPluginRecords < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:plugin_records)

    add_column :plugin_records, :author, :string unless column_exists?(:plugin_records, :author)
    add_column :plugin_records, :extension_points, :text unless column_exists?(:plugin_records, :extension_points)

    backfill_from_manifest_config
  end

  def down
    return unless table_exists?(:plugin_records)

    remove_column :plugin_records, :extension_points if column_exists?(:plugin_records, :extension_points)
    remove_column :plugin_records, :author if column_exists?(:plugin_records, :author)
  end

  private

  def backfill_from_manifest_config
    say_with_time "backfilling plugin_records filter columns from config->manifest" do
      PluginRecord.reset_column_information
      PluginRecord.find_each do |record|
        manifest = record.config.to_h.fetch("manifest", {})
        record.update_columns(
          author: manifest["author"],
          extension_points: extension_points_token_list(manifest["extension_points"])
        )
      end
    end
  end

  def extension_points_token_list(points)
    tokens = Array(points).map(&:to_s).reject(&:blank?).sort
    tokens.any? ? "\n#{tokens.join("\n")}\n" : nil
  end
end
