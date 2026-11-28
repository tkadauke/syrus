class CreateCoworkerJobAutonomyShadowDecisions < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:coworker_job_autonomy_shadow_decisions)

    create_table :coworker_job_autonomy_shadow_decisions do |t|
      t.references :coworker, null: false, foreign_key: false
      t.integer :permission_rule_id, null: false
      t.references :repository, null: false, foreign_key: false
      t.references :job, null: true, foreign_key: false
      t.references :chat_pending_action, null: false, foreign_key: false
      t.string :action, null: false
      t.string :predicted_decision, null: false
      t.json :evidence
      t.json :guardrail_outcomes
      t.string :operator_decision
      t.datetime :operator_decided_at
      t.timestamps
    end
    add_index :coworker_job_autonomy_shadow_decisions, :action unless index_exists?(:coworker_job_autonomy_shadow_decisions, :action)
    add_index :coworker_job_autonomy_shadow_decisions, :operator_decision unless index_exists?(:coworker_job_autonomy_shadow_decisions, :operator_decision)
  end

  def down
    drop_table :coworker_job_autonomy_shadow_decisions if table_exists?(:coworker_job_autonomy_shadow_decisions)
  end
end
