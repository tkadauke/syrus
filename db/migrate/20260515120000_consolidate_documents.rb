class ConsolidateDocuments < ActiveRecord::Migration[8.1]
  def up
    create_table :documents do |t|
      t.string :attachable_type, null: false
      t.integer :attachable_id, null: false
      t.integer :user_id
      t.string :kind, null: false, default: "file"
      t.string :title, null: false
      t.string :google_doc_url
      t.text :content_cache, limit: 64.kilobytes
      t.datetime :content_cached_at
      t.string :source_url
      t.string :filename
      t.string :content_type
      t.bigint :byte_size
      t.timestamps
    end

    add_index :documents, [ :attachable_type, :attachable_id, :created_at ], name: "index_documents_on_attachable_and_created_at"
    add_index :documents, [ :attachable_type, :attachable_id, :source_url ], unique: true, name: "index_documents_on_attachable_and_source_url"
    add_index :documents, :user_id
    add_foreign_key :documents, :users

    migrate_repository_documents if table_exists?(:repository_documents)
    migrate_job_attachments if table_exists?(:job_attachments)

    drop_table :repository_documents if table_exists?(:repository_documents)
    drop_table :job_attachments if table_exists?(:job_attachments)
  end

  def down
    create_table :repository_documents do |t|
      t.text :content_cache, limit: 64.kilobytes
      t.datetime :content_cached_at
      t.datetime :created_at, null: false
      t.string :google_docs_url
      t.string :kind, null: false
      t.integer :repository_id, null: false
      t.string :title, null: false
      t.datetime :updated_at, null: false
      t.integer :user_id, null: false
    end
    add_index :repository_documents, [ :repository_id, :created_at ], name: "index_repository_documents_on_repository_id_and_created_at"
    add_index :repository_documents, :repository_id
    add_index :repository_documents, :user_id

    create_table :job_attachments do |t|
      t.string :attachment_type, default: "uploaded_file", null: false
      t.bigint :byte_size
      t.string :content_type
      t.datetime :created_at, null: false
      t.string :filename
      t.string :google_doc_url
      t.integer :job_id, null: false
      t.string :source_url
      t.datetime :updated_at, null: false
    end
    add_index :job_attachments, [ :job_id, :created_at ], name: "index_job_attachments_on_job_id_and_created_at"
    add_index :job_attachments, [ :job_id, :source_url ], unique: true, name: "index_job_attachments_on_job_id_and_source_url"
    add_index :job_attachments, :job_id

    migrate_documents_down
    drop_table :documents
  end

  private

  def migrate_repository_documents
    select_all("SELECT * FROM repository_documents").each do |row|
      id = insert_document!(
        attachable_type: "Repository",
        attachable_id: row["repository_id"],
        user_id: row["user_id"],
        kind: row["kind"],
        title: row["title"],
        google_doc_url: row["google_docs_url"],
        content_cache: row["content_cache"],
        content_cached_at: row["content_cached_at"],
        created_at: row["created_at"],
        updated_at: row["updated_at"]
      )
      move_attachment!("RepositoryDocument", row["id"], "Document", id)
    end
  end

  def migrate_job_attachments
    select_all("SELECT job_attachments.*, jobs.user_id FROM job_attachments INNER JOIN jobs ON jobs.id = job_attachments.job_id").each do |row|
      kind = row["attachment_type"] == "google_doc_link" ? "google_doc" : "file"
      title = row["filename"].presence || (kind == "google_doc" ? "Google Doc" : "Attachment")
      id = insert_document!(
        attachable_type: "Job",
        attachable_id: row["job_id"],
        user_id: row["user_id"],
        kind: kind,
        title: title,
        google_doc_url: row["google_doc_url"],
        source_url: row["source_url"],
        filename: row["filename"],
        content_type: row["content_type"],
        byte_size: row["byte_size"],
        created_at: row["created_at"],
        updated_at: row["updated_at"]
      )
      move_attachment!("JobAttachment", row["id"], "Document", id)
    end
  end

  def migrate_documents_down
    select_all("SELECT * FROM documents").each do |row|
      case row["attachable_type"]
      when "Repository"
        id = insert_repository_document!(row)
        move_attachment!("Document", row["id"], "RepositoryDocument", id)
      when "Job"
        id = insert_job_attachment!(row)
        move_attachment!("Document", row["id"], "JobAttachment", id)
      end
    end
  end

  def insert_document!(attrs)
    insert(<<~SQL.squish)
      INSERT INTO documents
        (attachable_type, attachable_id, user_id, kind, title, google_doc_url, content_cache, content_cached_at, source_url, filename, content_type, byte_size, created_at, updated_at)
      VALUES
        (#{quote(attrs[:attachable_type])}, #{quote(attrs[:attachable_id])}, #{quote(attrs[:user_id])}, #{quote(attrs[:kind])}, #{quote(attrs[:title])}, #{quote(attrs[:google_doc_url])}, #{quote(attrs[:content_cache])}, #{quote(attrs[:content_cached_at])}, #{quote(attrs[:source_url])}, #{quote(attrs[:filename])}, #{quote(attrs[:content_type])}, #{quote(attrs[:byte_size])}, #{quote(attrs[:created_at])}, #{quote(attrs[:updated_at])})
    SQL
  end

  def insert_repository_document!(row)
    insert(<<~SQL.squish)
      INSERT INTO repository_documents
        (repository_id, user_id, kind, title, google_docs_url, content_cache, content_cached_at, created_at, updated_at)
      VALUES
        (#{quote(row["attachable_id"])}, #{quote(row["user_id"])}, #{quote(row["kind"])}, #{quote(row["title"])}, #{quote(row["google_doc_url"])}, #{quote(row["content_cache"])}, #{quote(row["content_cached_at"])}, #{quote(row["created_at"])}, #{quote(row["updated_at"])})
    SQL
  end

  def insert_job_attachment!(row)
    attachment_type = row["kind"] == "google_doc" ? "google_doc_link" : "uploaded_file"
    insert(<<~SQL.squish)
      INSERT INTO job_attachments
        (job_id, attachment_type, google_doc_url, source_url, filename, content_type, byte_size, created_at, updated_at)
      VALUES
        (#{quote(row["attachable_id"])}, #{quote(attachment_type)}, #{quote(row["google_doc_url"])}, #{quote(row["source_url"])}, #{quote(row["filename"])}, #{quote(row["content_type"])}, #{quote(row["byte_size"])}, #{quote(row["created_at"])}, #{quote(row["updated_at"])})
    SQL
  end

  def move_attachment!(old_type, old_id, new_type, new_id)
    execute(<<~SQL.squish)
      UPDATE active_storage_attachments
      SET record_type = #{quote(new_type)}, record_id = #{quote(new_id)}
      WHERE record_type = #{quote(old_type)} AND record_id = #{quote(old_id)}
    SQL
  end
end
