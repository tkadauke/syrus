class DropAttentionItems < ActiveRecord::Migration[8.1]
  def up
    drop_table :attention_items, if_exists: true
  end

  def down
    return if table_exists?(:attention_items)

    create_table :attention_items do |t|
      t.json :actions, null: false
      t.json :adjudication
      t.datetime :created_at, null: false
      t.datetime :decided_at
      t.integer :decided_by_user_id
      t.json :evidence, null: false
      t.datetime :expires_at
      t.integer :job_id
      t.string :problem_code, null: false
      t.string :signature, null: false
      t.string :queue, null: false, default: "operator"
      t.string :urgency, null: false, default: "normal"
      t.string :state, null: false, default: "open"
      t.integer :repository_id
      t.string :resolution
      t.text :reason
      t.integer :step_id
      t.text :summary
      t.string :title, null: false
      t.datetime :updated_at, null: false
      t.integer :user_id
      t.integer :workflow_id
    end

    add_index :attention_items, :decided_by_user_id
    add_index :attention_items, :job_id
    add_index :attention_items, :problem_code
    add_index :attention_items, [ :queue, :state, :urgency ], name: "index_attention_items_on_queue_state_urgency"
    add_index :attention_items, :repository_id
    add_index :attention_items, [ :signature, :state ]
    add_index :attention_items, :step_id
    add_index :attention_items, :user_id
    add_index :attention_items, :workflow_id
  end
end
