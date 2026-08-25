module WorkIntents
  class TerminalUnitSync
    ACTIVE_UNIT_STATES = %w[queued blocked running].freeze
    SUPERSEDING_CANCEL_REASONS = [
      Workflow::SUPERSEDED_BY_REBASE_REASON,
      "operator_cancelled",
      "job_approved"
    ].freeze

    def self.call(work_unit) = new(work_unit).call

    def initialize(work_unit)
      @work_unit = work_unit
    end

    def call
      return unless work_unit&.terminal?

      intent = work_unit.work_intent
      return unless intent&.requested? || intent&.waiting?
      return if active_sibling_unit?(intent)

      if work_unit.succeeded?
        intent.satisfy!
      elsif work_unit.failed?
        intent.fail!
      elsif cancelled_by_superseding_work?(work_unit)
        intent.cancel!
      end
    end

    private

    attr_reader :work_unit

    def cancelled_by_superseding_work?(unit)
      unit.cancelled? && unit.preemption_reason.in?(SUPERSEDING_CANCEL_REASONS)
    end

    def active_sibling_unit?(intent)
      intent.work_units
        .where(state: ACTIVE_UNIT_STATES)
        .where.not(id: work_unit.id)
        .exists?
    end
  end
end
