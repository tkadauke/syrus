class Coworkers::ReviewEvidenceTarget
  class << self
    def resolve(evidence, run: evidence.run)
      target = evidence.target_envelope.to_h
      if target.present?
        return unless target["type"] == Coworkers::ReviewerTargetProvider.target_type

        return ReviewerTargets.resolve(
          target,
          owner: run.job.owner_user || run.job.user,
          repository: run.job.repository
        ).fetch(:record)
      end

      return unless evidence.reviewer_type == "Coworkers::Coworker"

      Coworkers::Coworker.find_by(id: evidence.reviewer_id)
    end
  end
end
