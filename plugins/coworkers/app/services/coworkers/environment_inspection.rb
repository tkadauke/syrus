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
    revisions = environment.revisions.includes(:build_request, :runtime_image).reorder(number: :desc).to_a
    active = environment.active_revision
    candidate = environment.candidate_revision
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
