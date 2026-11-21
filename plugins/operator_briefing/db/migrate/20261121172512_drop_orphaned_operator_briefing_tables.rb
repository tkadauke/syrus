class DropOrphanedOperatorBriefingTables < ActiveRecord::Migration[8.1]
  # The removed notable-change detector wrote these. Its removal edited the
  # original migration instead of dropping them, so databases that ran it kept
  # both tables, and a later schema dump copied them back into db/schema.rb.
  # Nothing reads them. Idempotent: fresh installs never had them.
  def up
    drop_table :operator_briefing_review_findings, if_exists: true
    drop_table :operator_briefing_workflow_notable_changes, if_exists: true
  end

  # Their data came from a pipeline that no longer exists; there is nothing to
  # restore them for.
  def down; end
end
