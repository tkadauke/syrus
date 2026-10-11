module LandingFailureCode
  INFRASTRUCTURE_BLOCKER = "infrastructure_blocker".freeze
  TRANSIENT_BLOCKER = "transient_blocker".freeze
  REBASE_CAP_REACHED = "rebase_cap_reached".freeze
  MERGE_TRAIN_REBUILD_REQUIRED = "merge_train_rebuild_required".freeze
  LANDING_START_BLOCKED = "landing_start_blocked".freeze
  ATTRIBUTABLE_FAILURE = "attributable_failure".freeze

  class Base
    def self.code(value = nil)
      return @code = value.to_s if value

      @code
    end

    def code = self.class.code
    def pause_landing? = false
    def defer_landing? = false
    def skip_merge_train_cooldown? = false
    def landing_start_blocker? = false
    def merge_train_rebuild_required? = false
    def attributable_failure? = false
  end

  class InfrastructureBlocker < Base
    code INFRASTRUCTURE_BLOCKER

    def pause_landing? = true
    def defer_landing? = true
  end

  class TransientBlocker < Base
    code TRANSIENT_BLOCKER

    def defer_landing? = true
  end

  class RebaseCapReached < Base
    code REBASE_CAP_REACHED

    def defer_landing? = true
  end

  class MergeTrainRebuildRequired < Base
    code MERGE_TRAIN_REBUILD_REQUIRED

    def defer_landing? = true
    def skip_merge_train_cooldown? = true
    def merge_train_rebuild_required? = true
  end

  class LandingStartBlocked < Base
    code LANDING_START_BLOCKED

    def defer_landing? = true
    def skip_merge_train_cooldown? = true
    def landing_start_blocker? = true
  end

  class AttributableFailure < Base
    code ATTRIBUTABLE_FAILURE

    def attributable_failure? = true
  end

  CLASSES = [
    InfrastructureBlocker,
    TransientBlocker,
    RebaseCapReached,
    MergeTrainRebuildRequired,
    LandingStartBlocked,
    AttributableFailure
  ].freeze
  BY_CODE = CLASSES.index_by(&:code).freeze
  PROBLEM_CODE_ALIASES = {
    "disk_full" => INFRASTRUCTURE_BLOCKER,
    "storage_unavailable" => TRANSIENT_BLOCKER,
    "timeout" => TRANSIENT_BLOCKER,
    "workspace_clone_timeout" => TRANSIENT_BLOCKER,
    "worker_died" => TRANSIENT_BLOCKER,
    "worker_died_under_resource_pressure" => TRANSIENT_BLOCKER,
    "database_lock" => TRANSIENT_BLOCKER
  }.freeze

  module_function

  def resolve(code)
    BY_CODE[code.to_s]&.new
  end

  def fetch(code)
    resolve(code) || raise(ArgumentError, "unknown landing failure code=#{code.inspect}")
  end

  def values = BY_CODE.keys.freeze

  def from_problem(problem)
    return unless problem

    resolve(PROBLEM_CODE_ALIASES.fetch(problem.code, problem.code))
  end

  # Compatibility for rows written before landing failures had structured
  # codes. Current handlers persist a code before control-flow decisions, and
  # new callers should pass/read that code instead of depending on prose.
  def legacy_from_reason(reason)
    text = reason.to_s
    return resolve(MERGE_TRAIN_REBUILD_REQUIRED) if LandingFailureHandler.merge_train_rebuild_required?(text)
    return resolve(LANDING_START_BLOCKED) if LandingQueueReentry.legacy_landing_start_blocker_reason?(text)
    return resolve(INFRASTRUCTURE_BLOCKER) if LandingFailureHandler.infrastructure_blocker?(text)
    return resolve(REBASE_CAP_REACHED) if text.match?(/rebase cap reached/i)
    return resolve(TRANSIENT_BLOCKER) if LandingFailureHandler.transient_blocker?(text)
    return resolve(TRANSIENT_BLOCKER) if text.start_with?(MergeTrain::STALE_RUNTIME_FAILURE_REASON)

    nil
  end
end
