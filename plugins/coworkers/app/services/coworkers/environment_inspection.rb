# Resolves the records needed to inspect a coworker's environment without
# exposing restricted build evidence. Presentation stays in the serializer so
# tools, UI, and operational surfaces share one stable safe contract.
class Coworkers::EnvironmentInspection
  HISTORY_LIMIT = 50

  Snapshot = Data.define(:environment, :source_revision, :build_revision, :candidate_revision,
                         :active_revision, :rollback_revisions, :active_base, :revisions)

  def initialize(environment)
    @environment = environment
  end

  def call
    environment = @environment.reload
    eligible_rollback = Coworkers::EnvironmentRecovery.new(environment).eligible_rollback_revision
    recent_revision_ids = environment.revisions.reorder(number: :desc).limit(HISTORY_LIMIT).select(:id)
    referenced_ids = [ environment.active_revision_id, environment.candidate_revision_id, eligible_rollback&.id ].compact
    revisions_scope = environment.revisions.where(id: recent_revision_ids)
    revisions_scope = revisions_scope.or(environment.revisions.where(id: referenced_ids)) if referenced_ids.any?
    revisions = revisions_scope
      .includes(:runtime_image, :base_release, build_request: [ :result, { evidences: :attempt } ])
      .reorder(number: :desc).to_a
    revisions_by_id = revisions.index_by(&:id)
    active = revisions_by_id[environment.active_revision_id]
    candidate = revisions_by_id[environment.candidate_revision_id]
    build_revision = revisions.find { |revision| revision.build_request.present? }
    platform = candidate&.runtime_image&.platform || active&.runtime_image&.platform || "linux/amd64"

    Snapshot.new(
      environment:, source_revision: revisions.first, build_revision:, candidate_revision: candidate,
      active_revision: active, rollback_revisions: rollback_revisions(revisions, eligible_rollback:),
      active_base: Syrus::Host::RuntimeImages.active_base(platform:), revisions:
    )
  end

  private

  def rollback_revisions(revisions, eligible_rollback:)
    revision = revisions.index_by(&:id)[eligible_rollback&.id]
    revision ? [ revision ] : []
  end
end
