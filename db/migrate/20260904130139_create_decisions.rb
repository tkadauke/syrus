class CreateDecisions < ActiveRecord::Migration[8.1]
  # The unit of operator attention (workflow-engine-v3 B2). One problem, its
  # evidence, the adjudicator's verdict, and the typed actions that resolve it.
  def up
    create_table :decisions, if_not_exists: true do |t|
      t.string :problem_code, null: false
      # Problem code plus a normalized evidence fingerprint. B3 consults this
      # from rung 0 so a decision made once stops being asked again.
      t.string :signature, null: false
      t.string :state, null: false, default: "open"
      # Which queue this belongs to: operator decisions and bug triage share
      # the mechanism but not the audience, the SLA, or the routing.
      t.string :queue, null: false, default: "operator"
      t.string :urgency, null: false, default: "normal"
      t.string :title, null: false
      t.text :summary

      t.references :user, null: true, foreign_key: true
      t.references :repository, null: true, foreign_key: true
      t.references :job, null: true, foreign_key: true
      t.references :workflow, null: true, foreign_key: true
      t.references :step, null: true, foreign_key: true

      t.references :decided_by_user, null: true, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.string :resolution
      t.text :reason
      t.datetime :expires_at

      t.timestamps
    end

    # JSON columns cannot carry a default on MySQL 8.
    add_column :decisions, :evidence, :json unless column_exists?(:decisions, :evidence)
    execute "UPDATE decisions SET evidence = '{}' WHERE evidence IS NULL"
    change_column_null :decisions, :evidence, false

    add_column :decisions, :adjudication, :json unless column_exists?(:decisions, :adjudication)
    add_column :decisions, :actions, :json unless column_exists?(:decisions, :actions)
    execute "UPDATE decisions SET actions = '[]' WHERE actions IS NULL"
    change_column_null :decisions, :actions, false

    add_index :decisions, [ :queue, :state, :urgency ], name: "index_decisions_on_queue_state_urgency" unless index_exists?(:decisions, [ :queue, :state, :urgency ], name: "index_decisions_on_queue_state_urgency")
    add_index :decisions, [ :signature, :state ] unless index_exists?(:decisions, [ :signature, :state ])
    add_index :decisions, :problem_code unless index_exists?(:decisions, :problem_code)
  end

  def down
    drop_table :decisions, if_exists: true
  end
end
