class CreateDesignDocs < ActiveRecord::Migration[8.1]
  def change
    create_table :design_docs, if_not_exists: true do |t|
      t.string :title, null: false
      t.text :markdown, null: false
      t.integer :owner_user_id, null: false
      t.string :visibility, null: false, default: "private"
      t.string :state, null: false, default: "draft"
      t.integer :origin_chat_session_id
      t.integer :current_version_id

      t.timestamps
    end

    add_index :design_docs, :owner_user_id unless index_exists?(:design_docs, :owner_user_id)
    add_index :design_docs, :origin_chat_session_id unless index_exists?(:design_docs, :origin_chat_session_id)
    add_index :design_docs, :current_version_id unless index_exists?(:design_docs, :current_version_id)
    add_index :design_docs, [ :visibility, :state ], name: "index_design_docs_on_visibility_and_state" unless index_exists?(:design_docs, [ :visibility, :state ], name: "index_design_docs_on_visibility_and_state")

    create_table :design_doc_repositories, if_not_exists: true do |t|
      t.references :design_doc, null: false, foreign_key: false
      t.references :repository, null: false, foreign_key: false

      t.timestamps
    end

    add_index :design_doc_repositories, [ :design_doc_id, :repository_id ], unique: true, name: "index_design_doc_repositories_on_doc_and_repository" unless index_exists?(:design_doc_repositories, [ :design_doc_id, :repository_id ], name: "index_design_doc_repositories_on_doc_and_repository")
    add_index :design_doc_repositories, :repository_id unless index_exists?(:design_doc_repositories, :repository_id)

    create_table :design_doc_collaborators, if_not_exists: true do |t|
      t.references :design_doc, null: false, foreign_key: false
      t.references :user, null: false, foreign_key: false
      t.string :role, null: false, default: "editor"
      t.integer :added_by_user_id

      t.timestamps
    end

    add_index :design_doc_collaborators, [ :design_doc_id, :user_id ], unique: true, name: "index_design_doc_collaborators_on_doc_and_user" unless index_exists?(:design_doc_collaborators, [ :design_doc_id, :user_id ], name: "index_design_doc_collaborators_on_doc_and_user")
    add_index :design_doc_collaborators, :user_id unless index_exists?(:design_doc_collaborators, :user_id)
    add_index :design_doc_collaborators, :added_by_user_id unless index_exists?(:design_doc_collaborators, :added_by_user_id)

    create_table :design_doc_versions, if_not_exists: true do |t|
      t.references :design_doc, null: false, foreign_key: false
      t.text :markdown, null: false
      t.integer :version_number, null: false
      t.integer :actor_user_id
      t.string :actor_kind, null: false
      t.string :provenance_type
      t.integer :provenance_id
      t.text :change_summary
      t.json :metadata

      t.timestamps
    end

    add_index :design_doc_versions, [ :design_doc_id, :version_number ], unique: true, name: "index_design_doc_versions_on_doc_and_number" unless index_exists?(:design_doc_versions, [ :design_doc_id, :version_number ], name: "index_design_doc_versions_on_doc_and_number")
    add_index :design_doc_versions, :actor_user_id unless index_exists?(:design_doc_versions, :actor_user_id)
    add_index :design_doc_versions, [ :provenance_type, :provenance_id ], name: "index_design_doc_versions_on_provenance" unless index_exists?(:design_doc_versions, [ :provenance_type, :provenance_id ], name: "index_design_doc_versions_on_provenance")

    create_table :design_doc_anchors, if_not_exists: true do |t|
      t.references :design_doc, null: false, foreign_key: false
      t.string :anchor_key, null: false
      t.integer :design_doc_version_id
      t.integer :start_offset, null: false
      t.integer :end_offset, null: false
      t.text :selected_markdown

      t.timestamps
    end

    add_index :design_doc_anchors, [ :design_doc_id, :anchor_key ], unique: true, name: "index_design_doc_anchors_on_doc_and_key" unless index_exists?(:design_doc_anchors, [ :design_doc_id, :anchor_key ], name: "index_design_doc_anchors_on_doc_and_key")
    add_index :design_doc_anchors, :design_doc_version_id unless index_exists?(:design_doc_anchors, :design_doc_version_id)

    create_table :design_doc_threads, if_not_exists: true do |t|
      t.references :design_doc, null: false, foreign_key: false
      t.references :design_doc_anchor, null: false, foreign_key: false
      t.integer :opened_by_user_id
      t.string :state, null: false, default: "open"
      t.datetime :resolved_at
      t.integer :resolved_by_user_id

      t.timestamps
    end

    add_index :design_doc_threads, [ :design_doc_id, :state ], name: "index_design_doc_threads_on_doc_and_state" unless index_exists?(:design_doc_threads, [ :design_doc_id, :state ], name: "index_design_doc_threads_on_doc_and_state")
    add_index :design_doc_threads, :design_doc_anchor_id unless index_exists?(:design_doc_threads, :design_doc_anchor_id)
    add_index :design_doc_threads, :opened_by_user_id unless index_exists?(:design_doc_threads, :opened_by_user_id)
    add_index :design_doc_threads, :resolved_by_user_id unless index_exists?(:design_doc_threads, :resolved_by_user_id)

    create_table :design_doc_comments, if_not_exists: true do |t|
      t.references :design_doc_thread, null: false, foreign_key: false
      t.integer :author_user_id
      t.string :author_kind, null: false
      t.text :body, null: false

      t.timestamps
    end

    add_index :design_doc_comments, :author_user_id unless index_exists?(:design_doc_comments, :author_user_id)
    add_index :design_doc_comments, [ :design_doc_thread_id, :created_at ], name: "index_design_doc_comments_on_thread_and_created_at" unless index_exists?(:design_doc_comments, [ :design_doc_thread_id, :created_at ], name: "index_design_doc_comments_on_thread_and_created_at")

    create_table :design_doc_suggestions, if_not_exists: true do |t|
      t.references :design_doc, null: false, foreign_key: false
      t.references :design_doc_anchor, null: false, foreign_key: false
      t.references :design_doc_thread, foreign_key: false
      t.integer :suggested_by_user_id
      t.string :suggested_by_kind, null: false
      t.string :state, null: false, default: "pending"
      t.text :original_markdown, null: false
      t.text :suggested_markdown, null: false
      t.text :change_summary
      t.datetime :reviewed_at
      t.integer :reviewed_by_user_id

      t.timestamps
    end

    add_index :design_doc_suggestions, [ :design_doc_anchor_id, :state ], name: "index_design_doc_suggestions_on_anchor_and_state" unless index_exists?(:design_doc_suggestions, [ :design_doc_anchor_id, :state ], name: "index_design_doc_suggestions_on_anchor_and_state")
    add_index :design_doc_suggestions, [ :design_doc_id, :state ], name: "index_design_doc_suggestions_on_doc_and_state" unless index_exists?(:design_doc_suggestions, [ :design_doc_id, :state ], name: "index_design_doc_suggestions_on_doc_and_state")
    add_index :design_doc_suggestions, :suggested_by_user_id unless index_exists?(:design_doc_suggestions, :suggested_by_user_id)
    add_index :design_doc_suggestions, :reviewed_by_user_id unless index_exists?(:design_doc_suggestions, :reviewed_by_user_id)

    add_foreign_key :design_docs, :users, column: :owner_user_id unless foreign_key_exists?(:design_docs, :users, column: :owner_user_id)
    add_foreign_key :design_docs, :chat_sessions, column: :origin_chat_session_id unless foreign_key_exists?(:design_docs, :chat_sessions, column: :origin_chat_session_id)
    add_foreign_key :design_doc_repositories, :design_docs unless foreign_key_exists?(:design_doc_repositories, :design_docs)
    add_foreign_key :design_doc_repositories, :repositories unless foreign_key_exists?(:design_doc_repositories, :repositories)
    add_foreign_key :design_doc_collaborators, :design_docs unless foreign_key_exists?(:design_doc_collaborators, :design_docs)
    add_foreign_key :design_doc_collaborators, :users unless foreign_key_exists?(:design_doc_collaborators, :users)
    add_foreign_key :design_doc_collaborators, :users, column: :added_by_user_id unless foreign_key_exists?(:design_doc_collaborators, :users, column: :added_by_user_id)
    add_foreign_key :design_doc_versions, :design_docs unless foreign_key_exists?(:design_doc_versions, :design_docs)
    add_foreign_key :design_doc_versions, :users, column: :actor_user_id unless foreign_key_exists?(:design_doc_versions, :users, column: :actor_user_id)
    add_foreign_key :design_docs, :design_doc_versions, column: :current_version_id unless foreign_key_exists?(:design_docs, :design_doc_versions, column: :current_version_id)
    add_foreign_key :design_doc_anchors, :design_docs unless foreign_key_exists?(:design_doc_anchors, :design_docs)
    add_foreign_key :design_doc_anchors, :design_doc_versions unless foreign_key_exists?(:design_doc_anchors, :design_doc_versions)
    add_foreign_key :design_doc_threads, :design_docs unless foreign_key_exists?(:design_doc_threads, :design_docs)
    add_foreign_key :design_doc_threads, :design_doc_anchors unless foreign_key_exists?(:design_doc_threads, :design_doc_anchors)
    add_foreign_key :design_doc_threads, :users, column: :opened_by_user_id unless foreign_key_exists?(:design_doc_threads, :users, column: :opened_by_user_id)
    add_foreign_key :design_doc_threads, :users, column: :resolved_by_user_id unless foreign_key_exists?(:design_doc_threads, :users, column: :resolved_by_user_id)
    add_foreign_key :design_doc_comments, :design_doc_threads unless foreign_key_exists?(:design_doc_comments, :design_doc_threads)
    add_foreign_key :design_doc_comments, :users, column: :author_user_id unless foreign_key_exists?(:design_doc_comments, :users, column: :author_user_id)
    add_foreign_key :design_doc_suggestions, :design_docs unless foreign_key_exists?(:design_doc_suggestions, :design_docs)
    add_foreign_key :design_doc_suggestions, :design_doc_anchors unless foreign_key_exists?(:design_doc_suggestions, :design_doc_anchors)
    add_foreign_key :design_doc_suggestions, :design_doc_threads unless foreign_key_exists?(:design_doc_suggestions, :design_doc_threads)
    add_foreign_key :design_doc_suggestions, :users, column: :suggested_by_user_id unless foreign_key_exists?(:design_doc_suggestions, :users, column: :suggested_by_user_id)
    add_foreign_key :design_doc_suggestions, :users, column: :reviewed_by_user_id unless foreign_key_exists?(:design_doc_suggestions, :users, column: :reviewed_by_user_id)
  end
end
