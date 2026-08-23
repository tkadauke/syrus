module WorkIntents
  class TerminalUnitSync
    ACTIVE_UNIT_STATES = %w[queued blocked running].freeze

    def self.call(work_unit) = new(work_unit).call

    def initialize(work_unit)
      @work_unit = work_unit
    end

    def call
      return unless work_unit&.succeeded?

      intent = work_unit.work_intent
      return unless intent&.requested? || intent&.waiting?
      return if active_sibling_unit?(intent)

      intent.satisfy!
    end

    private

    attr_reader :work_unit

    def active_sibling_unit?(intent)
      intent.work_units
        .where(state: ACTIVE_UNIT_STATES)
        .where.not(id: work_unit.id)
        .exists?
    end
  end
end
