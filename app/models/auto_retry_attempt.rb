class AutoRetryAttempt < ApplicationRecord
  include ValidatesAgentProvider

  # `preserved_merge_train` is a `failed_step` retry with one extra promise:
  # the merge-train failure handler decided to keep the assembled train and
  # its integration branch, so this attempt is what makes that decision real.
  # It is a distinct kind because preservation is granted for failures that
  # are deliberately *not* retryable -- a lost landing lock, a base that moved,
  # no capable worker -- and the generic retryability guards would otherwise
  # skip exactly the attempts the train is now waiting on.
  PRESERVED_MERGE_TRAIN_RETRY_KIND = "preserved_merge_train".freeze

  RETRY_KINDS = %w[ failed_step resume_failed_step retry_workflow preserved_merge_train ].freeze

  WORKER_DIED_CLASSIFICATION = "worker_died"
  MAX_ATTEMPTS = 3
  MAX_WORKER_DIED_ATTEMPTS = 20
  BACKOFFS = [ 5.minutes, 20.minutes, 1.hour ].freeze
  # Reasons a skipped attempt should NOT consume the retry budget: each names a
  # condition outside the Job's control that is expected to clear, so charging
  # the Job for it would spend its retries on the weather.
  #
  # Every entry must therefore describe something *transient*. A permanent
  # reason listed here is unbounded recursion: the attempt is skipped, the
  # budget does not advance, the planner sees budget available and plans
  # another. "failure classification changed" used to be here, and
  # `AutoRetryJob#skip_if_failure_no_longer_retryable` wrote a message with that
  # prefix whenever the fresh classification was non-retryable -- whether or not
  # anything had changed. Runs 121870/121914 produced ~460,000 attempts at two
  # per second before anyone noticed. That skip now writes
  # NOT_RETRYABLE_SKIP_PREFIX, which is deliberately absent from this list.
  BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES = [
    "That agent is not available",
    "Claude appears degraded",
    "Codex appears degraded",
    "job is terminal",
    "source workflow was already superseded",
    "failure classification changed",
    "default provider changed",
    "branch divergence recovered",
    "job branch was rewritten"
  ].freeze

  # The job's branch head moved after the source run recorded its workspace
  # head (e.g. a stack rebase force-pushed it). The workspace is stale, but the
  # pushed branch may already be correct, so the skip hands the job to the
  # reconciler for re-evaluation rather than dropping the work.
  BRANCH_REWRITTEN_SKIP_REASON = "job branch was rewritten since the source run recorded its workspace".freeze

  # A failure that is simply not retryable. Counts against the budget, so a
  # planner that keeps proposing retries runs out instead of spinning.
  NOT_RETRYABLE_SKIP_PREFIX = "failure is not retryable".freeze

  # Bounded categories for `skipped_reason`, safe to use as a metric tag (see
  # Syrus::Metrics::TagAllowlist) -- the raw string routinely carries
  # per-attempt interpolation (a classification name, a provider, another
  # attempt's schedule time) that would make it an unbounded label if used
  # directly. Built from the exact same prefixes that decide budget
  # exemption, so `syrus_auto_retry_attempts_total{skip_reason}` is a direct
  # instrument for BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES staying correct: a
  # permanent condition wrongly added to that list shows up here as a
  # specific, spiking category instead of disappearing into "other".
  SKIP_REASON_CATEGORIES = BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES.index_with { |prefix|
    prefix.parameterize(separator: "_")
  }.freeze

  # `skipped_reason` -> a small, bounded category for metrics/reporting.
  # `nil` (not skipped -- still pending, or already performed) categorizes as
  # "none".
  def self.skip_reason_category(skipped_reason)
    return "none" if skipped_reason.blank?
    return "not_retryable" if skipped_reason.start_with?(NOT_RETRYABLE_SKIP_PREFIX)

    _prefix, category = SKIP_REASON_CATEGORIES.find { |prefix, _| skipped_reason.start_with?(prefix) }
    category || "other"
  end

  belongs_to :job
  belongs_to :workflow
  belongs_to :run, optional: true

  before_validation :assign_retry_workflow_uniqueness_key

  validates_agent_provider
  validates :failure_classification, presence: true
  validates :retry_kind, presence: true, inclusion: { in: RETRY_KINDS }
  validates :attempt_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :scheduled_at, presence: true

  scope :budget_scope_for, ->(job:, agent_provider:, failure_classification:) {
    scope = where(
      job: job,
      agent_provider: agent_provider,
      failure_classification: failure_classification
    )
    exempt_clauses = BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES.map { "skipped_reason NOT LIKE ?" }.join(" AND ")
    exempt_values = BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES.map { |prefix| "#{sanitize_sql_like(prefix)}%" }

    scope.where(skipped_reason: nil).or(scope.where(exempt_clauses, *exempt_values))
  }

  # Not yet performed and not skipped — a retry that is still going to happen.
  scope :pending, -> { where(performed_at: nil, skipped_reason: nil) }
  scope :pending_in_schedule_order, -> { pending.order(:scheduled_at, :id) }
  scope :retry_workflow, -> { where(retry_kind: "retry_workflow") }
  scope :unskipped, -> { where(skipped_reason: nil) }

  def self.retry_workflow_scheduled_for?(workflow)
    where(workflow: workflow).retry_workflow.unskipped.exists?
  end

  def self.retry_budget_limit_for(classification)
    classification == WORKER_DIED_CLASSIFICATION ? MAX_WORKER_DIED_ATTEMPTS : MAX_ATTEMPTS
  end

  def self.prune_stale_pending!(limit: 1_000)
    count = 0

    pending_in_schedule_order
      .includes(:job, :workflow)
      .limit(limit)
      .each do |attempt|
        reason = attempt.stale_pending_reason
        next unless reason

        attempt.skip_stale_pending!(reason)
        count += 1
      end

    count
  end

  def stale_pending_reason
    return "job is terminal" if job&.state.in?(Job::TERMINAL_STATES)
    return "source workflow was already superseded by a successful workflow" if superseded_by_successful_workflow?
    return "source step already recovered" if run&.step&.state.in?(%w[succeeded skipped])
    return BRANCH_REWRITTEN_SKIP_REASON if branch_head_moved?

    nil
  end

  def skip_stale_pending!(reason)
    update!(skipped_reason: reason)
    WorkUnits::AutoRetryBackoff.clear!(self)
    request_reconciliation if reason == BRANCH_REWRITTEN_SKIP_REASON
  end

  private

  # Compares the head the source run recorded for its workspace against the PR
  # head GitHub reported at the latest mergeability check. Only trusted when
  # that check happened after the source run finished; otherwise the two SHAs
  # are simply from different moments and a difference proves nothing.
  def branch_head_moved?
    return false unless job && run
    recorded = run.head_sha.presence
    current = job.mergeability_head_sha.presence
    return false if recorded.blank? || current.blank?
    return false if run.finished_at.blank? || job.mergeability_checked_at.blank?
    return false if job.mergeability_checked_at <= run.finished_at

    recorded != current
  end

  def request_reconciliation
    WorkEngine::Reconciler.request(source: self.class.name, job: job, workflow: workflow)
  rescue StandardError => e
    Rails.logger.error("[AutoRetryAttempt] reconciliation request failed for #{job&.slug}: #{e.class}: #{e.message}")
  end

  def assign_retry_workflow_uniqueness_key
    self.retry_workflow_uniqueness_key = retry_kind == "retry_workflow" && skipped_reason.blank? ? "retry_workflow" : nil
  end

  def superseded_by_successful_workflow?
    Workflows::ValidationSupersession.superseded_by_successful_workflow?(workflow)
  end
end
