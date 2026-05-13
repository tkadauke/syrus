class AddInSyrusOperatorChat < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :allow_operator_chat, :string, default: "disabled", null: false

    create_table :operator_questions do |t|
      t.references :job, null: false, foreign_key: true
      t.references :workflow, null: false, foreign_key: true
      t.references :run, null: false, foreign_key: true
      t.text :text, null: false
      t.json :context, null: false
      t.datetime :asked_at, null: false
      t.timestamps

      t.index [ :run_id, :asked_at ]
    end

    create_table :operator_responses do |t|
      t.references :operator_question, null: false, foreign_key: true
      t.text :text, null: false
      t.datetime :responded_at, null: false
      t.timestamps

      t.index [ :operator_question_id, :responded_at ], name: "index_operator_responses_on_question_and_responded_at"
    end
  end
end
