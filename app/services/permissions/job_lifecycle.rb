module Permissions
  # Stable capability contracts for the core Job and Epic lifecycle tools.
  #
  # Every lifecycle tool maps to one operation under +syrus.jobs@v1+,
  # +syrus.epics@v1+, or +syrus.landing_queue@v1+. Single-Job and bulk
  # invocations of the same tool share one descriptor, and the classifier and
  # fingerprint normalizer collapse +job_id+ / +job_ids+ (and the Epic
  # equivalents) into the same canonical shape, so the evaluator sees identical
  # effects whether one record or many are targeted.
  #
  # Proposals (propose_job, propose_epic, ...) are deliberately not part of
  # this contract: they create reviewable proposal records, not lifecycle
  # changes, and keep their own lifecycle.
  class JobLifecycle
    Operation = Data.define(:capability, :name, :effects, :risk)

    JOBS = "syrus.jobs@v1".freeze
    EPICS = "syrus.epics@v1".freeze
    LANDING_QUEUE = "syrus.landing_queue@v1".freeze

    STATE_CHANGE = %i[internal_write].freeze
    WORK_CONTROL = %i[internal_write operational].freeze
    DESTRUCTIVE_CONTROL = %i[internal_write operational destructive].freeze

    OPERATIONS = {
      "create_coding_job" => Operation.new(JOBS, "create", STATE_CHANGE, :medium),
      "approve_job" => Operation.new(JOBS, "approve", STATE_CHANGE, :medium),
      "unapprove_job" => Operation.new(JOBS, "unapprove", STATE_CHANGE, :medium),
      "cancel_job" => Operation.new(JOBS, "cancel", DESTRUCTIVE_CONTROL, :high),
      "retry_job" => Operation.new(JOBS, "retry", WORK_CONTROL, :medium),
      "base_refresh_retry_job" => Operation.new(JOBS, "retry_base_refresh", WORK_CONTROL, :medium),
      "poll_job_feedback" => Operation.new(JOBS, "poll_feedback", WORK_CONTROL, :medium),
      "rebase_job" => Operation.new(JOBS, "rebase", WORK_CONTROL, :medium),
      "reopen_job" => Operation.new(JOBS, "reopen", WORK_CONTROL, :medium),
      "close_job_successfully" => Operation.new(JOBS, "close", STATE_CHANGE, :high),
      "check_job_mergeability" => Operation.new(JOBS, "check_mergeability", WORK_CONTROL, :low),
      "unland_job" => Operation.new(JOBS, "unland", WORK_CONTROL, :high),
      "start_epic" => Operation.new(EPICS, "start", WORK_CONTROL, :medium),
      "move_epic_to_backlog" => Operation.new(EPICS, "move_to_backlog", STATE_CHANGE, :medium),
      "archive_epic" => Operation.new(EPICS, "archive", STATE_CHANGE, :medium),
      "unland_epic" => Operation.new(EPICS, "unland", WORK_CONTROL, :high),
      "pause_landing_queue" => Operation.new(LANDING_QUEUE, "pause", WORK_CONTROL, :high),
      "resume_landing_queue" => Operation.new(LANDING_QUEUE, "resume", WORK_CONTROL, :medium),
      "wake_landing_queue" => Operation.new(LANDING_QUEUE, "wake", WORK_CONTROL, :medium),
      "force_landing_recheck" => Operation.new(LANDING_QUEUE, "force_recheck", WORK_CONTROL, :high),
      "override_landing_blocker_once" => Operation.new(LANDING_QUEUE, "override_blocker_once", DESTRUCTIVE_CONTROL, :critical)
    }.freeze

    # Argument keys that name the target records, mapped to the canonical key
    # the fingerprint uses. A singular and a plural spelling are equivalent.
    TARGET_KEYS = {
      "job_id" => "job_ids", "job_ids" => "job_ids",
      "epic_id" => "epic_ids", "epic_ids" => "epic_ids"
    }.freeze

    class << self
      def tool_names = OPERATIONS.keys

      def covers?(tool_name) = OPERATIONS.key?(tool_name.to_s)

      def descriptor_for(tool_name, required_roles: AgentRole::CHAT_ROLES)
        operation = OPERATIONS.fetch(tool_name.to_s)
        identifier = "#{operation.capability.delete_suffix('@v1')}/#{operation.name}@v1"
        roles = Array(required_roles)

        CapabilityDescriptor.new(
          capability: operation.capability,
          operation: identifier,
          effects: operation.effects,
          risk: operation.risk,
          requestable_roles: roles,
          defaults: roles.index_with { :ask },
          maximum_autonomy: :invocation,
          authority_durations: %i[invocation],
          resource_scope: { type: :none },
          classifier: ->(_arguments) { { operation: identifier, effects: operation.effects, risk: operation.risk, confidence: :certain } },
          fingerprint_normalizer: method(:normalize_arguments),
          redactor: method(:normalize_arguments)
        )
      end

      # Collapses singular/plural target arguments so a single-record call and
      # a one-element bulk call produce the same canonical arguments.
      def normalize_arguments(arguments)
        source = arguments.to_h.transform_keys(&:to_s)
        normalized = source.except(*TARGET_KEYS.keys)
        TARGET_KEYS.group_by { |_key, canonical| canonical }.each do |canonical, pairs|
          ids = pairs.flat_map { |key, _| Array(source[key]) }.compact.map { |id| Integer(id, exception: false) || id.to_s }
          normalized[canonical] = ids.uniq.sort_by(&:to_s) if ids.any?
        end
        normalized.sort_by { |key, _| key }.to_h
      end
    end
  end
end
