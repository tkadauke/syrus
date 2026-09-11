class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents do |t|
      t.string :resumable_type, null: false
      t.bigint :resumable_id, null: false
      t.timestamps

      t.index [ :resumable_type, :resumable_id ], unique: true, name: "index_agents_on_resumable"
    end
  end
end
