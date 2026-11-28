class Job
  module ClosureReason
    CATEGORIES = %w[delivered replaced declined gave_up external bookkeeping cancelled].freeze

    Entry = Data.define(:reason, :category, :success, :requires_reference, :requires_note, :agent_allowed) do
      def initialize(reason:, category:, success: false, requires_reference: false, requires_note: false, agent_allowed: true)
        category = category.to_s
        raise ArgumentError, "unknown closure category #{category.inspect}" unless CATEGORIES.include?(category)
        super(reason: reason.to_s, category:, success:, requires_reference:, requires_note:, agent_allowed:)
      end
    end

    BUILT_IN_ENTRIES = [
      *%w[pr_merged external_pr_merged emergency_landed hotfix_sync_landed promotion_landed investigation_reported already_implemented not_needed].map { |reason| Entry.new(reason:, category: "delivered", success: true) },
      Entry.new(reason: "implemented_elsewhere", category: "delivered", success: true, requires_reference: true),
      *%w[superseded duplicate merged_into split].map { |reason| Entry.new(reason:, category: "replaced", requires_reference: true) },
      Entry.new(reason: "obsolete", category: "declined", agent_allowed: false),
      Entry.new(reason: "wont_do", category: "declined", requires_note: true, agent_allowed: false),
      Entry.new(reason: "out_of_scope", category: "declined", agent_allowed: false),
      Entry.new(reason: "infeasible", category: "declined", requires_note: true, agent_allowed: false),
      *%w[too_many_failures too_many_workflows repair_exhausted].map { |reason| Entry.new(reason:, category: "gave_up") },
      *%w[issue_closed pr_closed external_pr_closed epic_archived repository_archived].map { |reason| Entry.new(reason:, category: "external") },
      *%w[main_grader preflight_passed preflight_inconclusive deploy local_mode_cancelled].map { |reason| Entry.new(reason:, category: "bookkeeping") },
      Entry.new(reason: "cancelled", category: "cancelled", agent_allowed: false)
    ].freeze

    REGISTRY = Syrus::KindRegistry.new(
      built_in: BUILT_IN_ENTRIES, entry_class: Entry, provider_method: :closure_reasons, key: :reason
    )

    module_function

    def entries = REGISTRY.entries
    def by_reason = REGISTRY.by_key
    def fetch(reason) = by_reason.fetch(reason.to_s)
    def values = by_reason.keys.freeze
    def successful_values = entries.select(&:success).map(&:reason).freeze
    def agent_values = entries.reject { |entry| entry.reason == "cancelled" }.map(&:reason).freeze
    def grouped_values = entries.group_by(&:category).transform_values { |items| items.map(&:reason) }.freeze
  end
end
