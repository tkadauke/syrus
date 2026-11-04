class CreateWorkflowVisualEvidences < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:workflow_visual_evidences)
      create_table :workflow_visual_evidences do |t|
        t.references :workflow, null: false
        t.references :run, null: false
        t.references :step, null: false
        t.string :stable_id, null: false
        t.integer :sequence, null: false
        t.string :status, null: false
        t.datetime :captured_at, null: false
        t.json :page_identity
        t.json :viewport
        t.string :device
        t.json :subject
        t.string :content_digest, null: false

        t.timestamps
      end
    end
    add_index :workflow_visual_evidences, :stable_id, unique: true unless index_exists?(:workflow_visual_evidences, :stable_id)
    add_index :workflow_visual_evidences, [ :run_id, :sequence ], unique: true unless index_exists?(:workflow_visual_evidences, [ :run_id, :sequence ])
    add_index :workflow_visual_evidences, [ :status, :captured_at ] unless index_exists?(:workflow_visual_evidences, [ :status, :captured_at ])
    add_index :workflow_visual_evidences, [ :run_id, :content_digest ] unless index_exists?(:workflow_visual_evidences, [ :run_id, :content_digest ])
  end


  def down
    drop_table :workflow_visual_evidences if table_exists?(:workflow_visual_evidences)
  end
end
