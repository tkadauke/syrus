class AddReviewEnvelopesToReviewEvidence < ActiveRecord::Migration[8.1]
  def change
    add_column :review_evidences, :target_envelope, :json unless column_exists?(:review_evidences, :target_envelope)
    add_column :review_evidences, :target_snapshot, :json unless column_exists?(:review_evidences, :target_snapshot)
    add_column :review_evidences, :context_envelope, :json unless column_exists?(:review_evidences, :context_envelope)
    add_column :review_evidences, :persistence_envelope, :json unless column_exists?(:review_evidences, :persistence_envelope)
  end
end
