class AddSkipMetadataToOperatorBriefingReviewFindings < ActiveRecord::Migration[8.1]
  def change
    add_column :operator_briefing_review_findings, :skipped, :boolean, null: false, default: false unless column_exists?(:operator_briefing_review_findings, :skipped)
    add_column :operator_briefing_review_findings, :skip_reason, :string unless column_exists?(:operator_briefing_review_findings, :skip_reason)
  end
end
