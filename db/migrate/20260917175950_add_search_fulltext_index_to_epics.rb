class AddSearchFulltextIndexToEpics < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_epics_on_search_fields"

  def up
    return unless mysql?
    return if index_exists?(:epics, [ :title, :description ], name: INDEX_NAME)

    add_index :epics, [ :title, :description ],
      type: :fulltext, name: INDEX_NAME
  end

  def down
    return unless mysql?
    return unless index_exists?(:epics, [ :title, :description ], name: INDEX_NAME)

    remove_index :epics, name: INDEX_NAME
  end

  private

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
