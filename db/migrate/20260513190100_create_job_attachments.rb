class CreateJobAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :job_attachments do |t|
      t.references :job, null: false, foreign_key: true
      t.string :attachment_type, null: false, default: "uploaded_file"
      t.string :google_doc_url
      t.string :source_url
      t.string :filename
      t.string :content_type
      t.bigint :byte_size

      t.timestamps

      t.index [ :job_id, :created_at ]
      t.index [ :job_id, :source_url ], unique: true
    end
  end
end
