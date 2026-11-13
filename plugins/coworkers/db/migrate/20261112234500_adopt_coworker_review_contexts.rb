# Corrective ownership migration. The coworker_review_contexts table was first
# created by a core migration (20261106105035), which has landed and must not be
# rewritten. This migration makes the Coworkers plugin the owner: on a fresh
# install after a plugin purge it recreates the table, and everywhere it adds
# the columns needed for conflict handling (lock_version), idempotency, and
# purge-safe journaling (evidence_snapshot), then backfills the opaque
# envelopes onto generic review evidence for historical coworker reviews.
class AdoptCoworkerReviewContexts < ActiveRecord::Migration[8.1]
  def up
    create_table :coworker_review_contexts, if_not_exists: true do |t|
      t.integer :run_id, null: false
      t.integer :review_evidence_id, null: false
      t.integer :coworker_id
      t.json :manifest
      t.text :exact_context
      t.string :workspace_path
      t.string :persistence_state, null: false, default: "prepared"
      t.string :persisted_commit_sha
      t.string :persistence_error_code
      t.json :persistence_error_details
      t.datetime :persisted_at
      t.datetime :tombstoned_at
      t.timestamps
    end
    add_index :coworker_review_contexts, :run_id, unique: true unless index_exists?(:coworker_review_contexts, :run_id)
    add_index :coworker_review_contexts, :review_evidence_id, unique: true unless index_exists?(:coworker_review_contexts, :review_evidence_id)

    add_column :coworker_review_contexts, :lock_version, :integer, null: false, default: 0 unless column_exists?(:coworker_review_contexts, :lock_version)
    add_column :coworker_review_contexts, :idempotency_key, :string unless column_exists?(:coworker_review_contexts, :idempotency_key)
    add_column :coworker_review_contexts, :evidence_snapshot, :json unless column_exists?(:coworker_review_contexts, :evidence_snapshot)
    add_index :coworker_review_contexts, :idempotency_key, unique: true unless index_exists?(:coworker_review_contexts, :idempotency_key)

    backfill_envelopes
  end

  def down
    # Additive and idempotent; the columns are harmless to keep.
  end

  private

  # Raw SQL on purpose: migrations must not depend on application models.
  def backfill_envelopes
    return unless column_exists?(:review_evidences, :target)

    select_rows(<<~SQL.squish).each do |id, reviewer_id, name, handle, role_summary, ctx_id, manifest, head, base|
      SELECT e.id, e.reviewer_id, c.name, c.handle, c.role_summary, rc.id, rc.manifest,
             e.reviewed_head_sha, e.reviewed_base_sha
      FROM review_evidences e
      LEFT JOIN coworkers c ON c.id = e.reviewer_id
      LEFT JOIN coworker_review_contexts rc ON rc.review_evidence_id = e.id
      WHERE e.reviewer_type = 'Coworkers::Coworker' AND e.target IS NULL
    SQL
      target = {
        "type" => "coworker", "reference" => reviewer_id.to_s,
        "display" => { "name" => name, "handle" => handle, "role_summary" => role_summary.to_s }.compact,
        "uniqueness_key" => reviewer_id.to_s
      }
      execute(sanitize_sql([ "UPDATE review_evidences SET target = ?, context_manifest = COALESCE(context_manifest, ?) WHERE id = ?",
                             JSON.generate(target), manifest, id ]))
      next unless ctx_id

      snapshot = { "review_evidence_id" => id, "reviewed_head_sha" => head, "reviewed_base_sha" => base }
      execute(sanitize_sql([ "UPDATE coworker_review_contexts SET evidence_snapshot = ?, idempotency_key = ? " \
                             "WHERE id = ? AND evidence_snapshot IS NULL",
                             JSON.generate(snapshot), "coworker-review-context:#{id}", ctx_id ]))
    end
  end

  def sanitize_sql(args) = ActiveRecord::Base.sanitize_sql_array(args)
end
