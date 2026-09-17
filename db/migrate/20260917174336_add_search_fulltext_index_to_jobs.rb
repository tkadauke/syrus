class AddSearchFulltextIndexToJobs < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_jobs_on_search_fields"

  def up
    return unless mysql?
    return if index_exists?(:jobs, [ :issue_title, :issue_body, :branch_name ], name: INDEX_NAME)

    add_index :jobs, [ :issue_title, :issue_body, :branch_name ],
      type: :fulltext, name: INDEX_NAME
  end

  def down
    return unless mysql?
    return unless index_exists?(:jobs, [ :issue_title, :issue_body, :branch_name ], name: INDEX_NAME)

    remove_index :jobs, name: INDEX_NAME
  end

  private

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
