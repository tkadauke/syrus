class CreateOperatorBriefingTopics < ActiveRecord::Migration[8.1]
  def change
    create_table :operator_briefing_topics, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: false
      t.references :first_seen_briefing_item, foreign_key: false
      t.string :slug, null: false
      t.string :title, null: false

      t.timestamps
    end

    unless index_exists?(:operator_briefing_topics, [ :repository_id, :slug ], name: "idx_operator_briefing_topics_repo_slug")
      add_index :operator_briefing_topics,
                [ :repository_id, :slug ],
                unique: true,
                name: "idx_operator_briefing_topics_repo_slug"
    end

    create_table :operator_briefing_topic_revisions, if_not_exists: true do |t|
      t.references :topic, null: false, foreign_key: false
      t.references :briefing, foreign_key: false
      t.references :workflow, foreign_key: false
      t.references :run, foreign_key: false
      t.integer :revision_number, null: false
      t.datetime :generated_at, null: false
      t.text :narrative, null: false
      t.json :findings
      t.json :references

      t.timestamps
    end

    unless index_exists?(:operator_briefing_topic_revisions, [ :topic_id, :revision_number ], name: "idx_operator_briefing_topic_revisions_number")
      add_index :operator_briefing_topic_revisions,
                [ :topic_id, :revision_number ],
                unique: true,
                name: "idx_operator_briefing_topic_revisions_number"
    end

    create_table :operator_briefing_topic_links, if_not_exists: true do |t|
      t.references :topic, null: false, foreign_key: false
      t.references :briefing, null: false, foreign_key: false
      t.references :workflow, foreign_key: false
      t.string :source_span

      t.timestamps
    end

    unless index_exists?(:operator_briefing_topic_links, [ :topic_id, :briefing_id, :workflow_id ], name: "idx_operator_briefing_topic_links_identity")
      add_index :operator_briefing_topic_links,
                [ :topic_id, :briefing_id, :workflow_id ],
                unique: true,
                name: "idx_operator_briefing_topic_links_identity"
    end
  end
end
