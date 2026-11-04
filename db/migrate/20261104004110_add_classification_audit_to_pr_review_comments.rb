class AddClassificationAuditToPrReviewComments < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_review_comments, :classification_decision, :string unless column_exists?(:pr_review_comments, :classification_decision)
    add_column :pr_review_comments, :classification_reason, :string unless column_exists?(:pr_review_comments, :classification_reason)
    add_column :pr_review_comments, :classification_source, :string unless column_exists?(:pr_review_comments, :classification_source)
    add_column :pr_review_comments, :classifier_version, :string unless column_exists?(:pr_review_comments, :classifier_version)
    add_column :pr_review_comments, :classification_error, :string unless column_exists?(:pr_review_comments, :classification_error)
    add_column :pr_review_comments, :qualified_for_workflow, :boolean unless column_exists?(:pr_review_comments, :qualified_for_workflow)
    add_column :pr_review_comments, :qualification_gate, :string unless column_exists?(:pr_review_comments, :qualification_gate)
  end
end
