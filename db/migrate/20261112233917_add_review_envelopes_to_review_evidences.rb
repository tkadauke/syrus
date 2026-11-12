# Opaque envelopes let a plugin attach reviewer context to generic review
# evidence without core holding a foreign key to (or a model of) plugin tables.
# - target:              immutable safe snapshot of the reviewer target (type/reference/display)
# - context_manifest:    write-once safe manifest of the restricted context (hashes, never text)
# - persistence_receipt: write-once opaque receipt of the post-verdict update
class AddReviewEnvelopesToReviewEvidences < ActiveRecord::Migration[8.1]
  def change
    add_column :review_evidences, :target, :json unless column_exists?(:review_evidences, :target)
    add_column :review_evidences, :context_manifest, :json unless column_exists?(:review_evidences, :context_manifest)
    add_column :review_evidences, :persistence_receipt, :json unless column_exists?(:review_evidences, :persistence_receipt)
  end
end
