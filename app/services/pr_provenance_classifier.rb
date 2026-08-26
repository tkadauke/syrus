# Classifies an externally-ingested pull request by Syrus provenance, per
# docs/plans/delivery-tracks-and-promotion.md Story 10. Structured Syrus
# metadata (a `PrProvenanceMarker` in the PR body, stamped by
# `Steps::PromotionPublish`/`Steps::UpstreamExportPublish`) wins when
# present; heuristics (branch naming, known-fork matching, release-branch
# targeting) are the fallback for PRs Syrus itself didn't author, or whose
# marker didn't survive (a human editing the PR body, a PR opened by a
# different tool against the same branch).
#
# Gated by `DeliveryPolicy#external_pr_ingest_classification_enabled?`
# (`external_prs.ingest.enabled` in `.syrus.yml`) — a repository that hasn't
# opted in gets every ingested PR classified `external_unknown`, identical
# to `Workflows::ExternalPrIngest`'s behavior before this classifier existed.
class PrProvenanceClassifier
  KINDS = %w[external_unknown syrus_job_export syrus_branch_export syrus_promotion manual_hotfix].freeze
  EXTERNAL_UNKNOWN = "external_unknown".freeze

  # Syrus branch names are always `syrus/<...>-<job id>` (see
  # `WorkflowWorkspace#initial_branch_name` — `syrus/direct-42`,
  # `syrus/issue-7-42`, `syrus/scheduled-3-42`, `syrus/local-42`). The
  # trailing digits are always the Job id on whichever Syrus instance cut
  # the branch.
  SYRUS_BRANCH_PREFIX = "syrus/".freeze
  JOB_ID_FROM_BRANCH_PATTERN = /-(?<job_id>\d+)\z/

  def self.classify(repository:, pr:)
    new(repository: repository, pr: pr).classify
  end

  def initialize(repository:, pr:)
    @repository = repository
    @pr = pr
  end

  def classify
    return EXTERNAL_UNKNOWN unless policy.external_pr_ingest_classification_enabled?

    from_marker || from_heuristics || EXTERNAL_UNKNOWN
  end

  # `syrus/direct-42` -> 42. `nil` for a branch with no trailing job id
  # (a hand-written branch, or a Syrus branch shape this parser doesn't
  # recognize). Exposed for `ExternalPrIngestions::SyrusJobExport` to reuse
  # without re-deriving the pattern.
  def self.job_id_from_branch(branch)
    match = branch.to_s.match(JOB_ID_FROM_BRANCH_PATTERN)
    match && match[:job_id].to_i
  end

  private

  attr_reader :repository, :pr

  def policy
    @policy ||= DeliveryPolicy.for(repository: repository)
  end

  def from_marker
    fields = PrProvenanceMarker.parse(pr.body)
    return nil unless fields

    kind = fields["kind"]
    KINDS.include?(kind) ? kind : nil
  end

  def from_heuristics
    return "manual_hotfix" if manual_hotfix?
    return "syrus_job_export" if syrus_job_export?
    return "syrus_branch_export" if syrus_branch_export?

    nil
  end

  def head_ref
    pr.head&.ref.to_s
  end

  def base_ref
    pr.base&.ref.to_s
  end

  def head_repo_slug
    pr.head&.repo&.full_name
  end

  def same_repo?
    head_repo_slug.present? && head_repo_slug == repository.slug
  end

  def syrus_branch?
    head_ref.start_with?(SYRUS_BRANCH_PREFIX)
  end

  # A fork we already know about because it registered on this instance with
  # `upstream_repository` pointing back at `repository` (Story 8: "A and B
  # share one Syrus instance"). A casual contributor's unregistered fork
  # (Story 9) never matches, and correctly falls through to
  # `external_unknown`.
  def known_fork
    return nil if same_repo? || head_repo_slug.blank?

    repository.fork_repositories.detect { |fork| fork.slug.casecmp?(head_repo_slug) }
  end

  # A Syrus per-job branch (`syrus/direct-42`, `syrus/issue-7-42`, ...) from
  # a known fork: Story 8/9's per-job upstream-export shape (Casey's PR).
  def syrus_job_export?
    return false unless syrus_branch?

    known_fork.present?
  end

  # A known fork's own development-track branch (not a per-job branch):
  # Story 11's whole-branch export shape (Bob's PR). Resolved against the
  # fork's own `.syrus.yml`, the same `DeliveryPolicy.for(repository: <other
  # repo>)` idiom `DeliveryPolicy#upstream_export_target_branch` already uses
  # to read a different repository's delivery config.
  def syrus_branch_export?
    return false if syrus_branch?

    fork = known_fork
    return false unless fork

    head_ref == DeliveryPolicy.for(repository: fork).job_landing_branch
  end

  # A same-repo PR (or already-merged commit surfaced as a PR) landing
  # directly on the release branch, bypassing the development track and any
  # Syrus-authored branch — Story 5/5A's direct-hotfix shape. Only
  # meaningful once the repository actually distinguishes a release branch
  # from a development branch (`hotfix_sync_enabled?`); otherwise "targets
  # the default branch" describes every ordinary external PR and would
  # misclassify them.
  def manual_hotfix?
    return false unless same_repo?
    return false if syrus_branch?
    return false unless policy.hotfix_sync_enabled?

    base_ref == policy.hotfix_sync_source_branch
  end
end
