class RemoveGoogleDocsFromDocuments < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM documents WHERE kind = 'google_doc'"
    remove_column :documents, :google_doc_url, :string if column_exists?(:documents, :google_doc_url)
    remove_column :documents, :content_cached_at, :datetime if column_exists?(:documents, :content_cached_at)
  end

  def down
    add_column :documents, :google_doc_url, :string unless column_exists?(:documents, :google_doc_url)
    add_column :documents, :content_cached_at, :datetime unless column_exists?(:documents, :content_cached_at)
  end
end
