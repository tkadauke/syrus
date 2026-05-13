class CreateJobAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :job_attachments do |t|
      t.references :job, null: false, foreign_key: true
      t.string :source_url, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false

      t.timestamps
    end

    add_index :job_attachments, [ :job_id, :source_url ], unique: true
  end
end
