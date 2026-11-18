class RemoveGoogleDocsFromDocuments < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM documents WHERE kind = 'google_doc'"
    remove_column :documents, :google_doc_url, :string
    remove_column :documents, :content_cache, :text
    remove_column :documents, :content_cached_at, :datetime
  end

  def down
    add_column :documents, :google_doc_url, :string
    add_column :documents, :content_cache, :text
    add_column :documents, :content_cached_at, :datetime
  end
end
