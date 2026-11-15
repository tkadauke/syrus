class BackfillCoworkerReviewEvidenceEnvelopes < ActiveRecord::Migration[8.1]
  class Evidence < ActiveRecord::Base
    self.table_name = "review_evidences"
  end

  class Coworker < ActiveRecord::Base
    self.table_name = "coworkers"
  end

  class Context < ActiveRecord::Base
    self.table_name = "coworker_review_contexts"
  end

  def up
    return unless table_exists?(:coworker_review_contexts)

    Evidence.where(reviewer_type: "Coworkers::Coworker").find_each do |evidence|
      coworker = Coworker.find_by(id: evidence.reviewer_id)
      context = Context.find_by(review_evidence_id: evidence.id)
      attributes = {}
      if coworker
        attributes[:target_envelope] = { "type" => "coworker", "reference" => coworker.id.to_s } if evidence.target_envelope.blank?
        attributes[:target_snapshot] = {
          "type" => "coworker", "reference" => coworker.id.to_s,
          "display" => { "name" => coworker.name, "handle" => coworker.handle },
          "uniqueness_key" => "coworker:#{coworker.id}"
        } if evidence.target_snapshot.blank?
      end
      if context
        attributes[:context_envelope] = {
          "owner" => "coworkers", "type" => "review_context", "version" => 1,
          "manifest" => context.manifest, "persistence_token" => context.id.to_s
        } if evidence.context_envelope.blank?
        if context.persistence_state == "persisted" && evidence.persistence_envelope.blank?
          attributes[:persistence_envelope] = {
            "owner" => "coworkers", "type" => "review_memory", "key" => context.id.to_s,
            "version" => context.updated_at.to_i, "persisted_at" => context.persisted_at&.iso8601,
            "details" => { "persisted_commit_sha" => context.persisted_commit_sha }
          }
        end
      end
      evidence.update_columns(attributes.compact) if attributes.any?
    end
  end

  def down
    # Historical envelopes are safe generic snapshots and remain useful after
    # the Coworkers plugin is disabled or removed.
  end
end
