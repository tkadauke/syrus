class AddSearchFieldsToPluginRecords < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:plugin_records)

    add_column :plugin_records, :display_name, :string unless column_exists?(:plugin_records, :display_name)
    add_column :plugin_records, :description, :text unless column_exists?(:plugin_records, :description)
    add_column :plugin_records, :category, :string unless column_exists?(:plugin_records, :category)

    backfill_from_manifest_config

    return unless mysql?
    return if index_exists?(:plugin_records, [ :name, :display_name, :description, :category ], name: "index_plugin_records_on_search_fields")

    add_index :plugin_records, [ :name, :display_name, :description, :category ],
      type: :fulltext, name: "index_plugin_records_on_search_fields"
  end

  def down
    return unless table_exists?(:plugin_records)

    remove_index :plugin_records, name: "index_plugin_records_on_search_fields" if index_exists?(:plugin_records, name: "index_plugin_records_on_search_fields")
    remove_column :plugin_records, :category if column_exists?(:plugin_records, :category)
    remove_column :plugin_records, :description if column_exists?(:plugin_records, :description)
    remove_column :plugin_records, :display_name if column_exists?(:plugin_records, :display_name)
  end

  private

  # `config` is a JSON column that already carries the manifest snapshot
  # (see Syrus::PluginRegistry.upsert_plugin_record!). Copy it into plain
  # text columns so MySQL can FULLTEXT-index it directly.
  def backfill_from_manifest_config
    say_with_time "backfilling plugin_records search columns from config->manifest" do
      execute(<<~SQL)
        UPDATE plugin_records
        SET
          display_name = #{manifest_json_extract('display_name')},
          description = #{manifest_json_extract('description')},
          category = #{manifest_json_extract('category')}
      SQL
    end
  end

  def manifest_json_extract(key)
    if mysql?
      "JSON_UNQUOTE(JSON_EXTRACT(config, '$.manifest.#{key}'))"
    else
      "json_extract(config, '$.manifest.#{key}')"
    end
  end

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
