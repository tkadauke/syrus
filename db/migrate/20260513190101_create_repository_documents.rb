class CreateRepositoryDocuments < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:repository_documents)

    create_table :repository_documents do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :title, null: false
      t.string :google_docs_url
      t.text :content_cache, limit: 64.kilobytes
      t.datetime :content_cached_at

      t.timestamps
    end

    add_index :repository_documents, [ :repository_id, :created_at ]
  end
end
