# Resolves the records needed to inspect a coworker's environment without
# exposing restricted build evidence. Presentation stays in the serializer so
# tools, UI, and operational surfaces share one stable safe contract.
class Coworkers::EnvironmentInspection
  Snapshot = Data.define(:environment, :source_revision, :build_revision, :candidate_revision,
                         :active_revision, :rollback_revisions, :active_base)

  def initialize(environment)
    @environment = environment
  end

  def call
    environment = @environment.reload
    revisions = environment.revisions
      .includes({ runtime_image: { runtime_image_verification_attempts: :attestation } }, build_request: [ :result, { evidences: :attempt } ])
      .reorder(number: :desc).to_a
    revisions_by_id = revisions.index_by(&:id)
    active = revisions_by_id[environment.active_revision_id]
    candidate = revisions_by_id[environment.candidate_revision_id]
    build_revision = revisions.find { |revision| revision.build_request.present? }
    platform = candidate&.runtime_image&.platform || active&.runtime_image&.platform || "linux/amd64"

    Snapshot.new(
      environment:, source_revision: revisions.first, build_revision:, candidate_revision: candidate,
      active_revision: active, rollback_revisions: rollback_revisions(revisions, active),
      active_base: Syrus::Host::RuntimeImages.active_base(platform:)
    )
  end

  private

  def rollback_revisions(revisions, active)
    revisions.select do |revision|
      image = revision.runtime_image
      revision.retired? && revision != active && image&.pullable? && image.retained?
    end
  end
end
