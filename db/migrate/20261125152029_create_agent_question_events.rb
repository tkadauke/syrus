class CreateAgentQuestionEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :agent_question_events, if_not_exists: true do |t|
      t.references :agent_question, null: false, foreign_key: false
      t.string :event_type, null: false
      t.string :source, null: false
      t.json :payload
      t.datetime :occurred_at, null: false

      t.timestamps
    end
  end

  def down
    drop_table :agent_question_events, if_exists: true
  end
end
