class Job
  # Registry of Job kinds. A Job kind says what a Job *is for* — an ingested
  # issue, a scheduled fire, an operator's direct prompt — and whether it is
  # operator-facing at all.
  #
  # `KINDS` used to be a frozen array literal on Job, which made a plugin that
  # runs its own kind of work (an insight sweep, a vendor-specific import)
  # impossible to build outside core: the Job it needed to create could not
  # pass validation. Plugins now contribute kinds through :workflow_kinds
  # alongside the trigger/step kinds of the workflow those Jobs run.
  module Kind
    Entry = Data.define(:kind, :infrastructure, :issueless) do
      # Both flags default off, so a plugin contributing an ordinary
      # operator-facing kind only has to name it.
      def initialize(kind:, infrastructure: false, issueless: false)
        super
      end
    end

    BUILT_IN_ENTRIES = [
      Entry.new(kind: "issue"),
      Entry.new(kind: "cron",        issueless: true),
      Entry.new(kind: "direct",      issueless: true),
      Entry.new(kind: "main_grader", issueless: true, infrastructure: true),
      Entry.new(kind: "external_pr", issueless: true),
      Entry.new(kind: "deploy",      issueless: true, infrastructure: true)
    ].freeze

    REGISTRY = Syrus::KindRegistry.new(
      built_in: BUILT_IN_ENTRIES, entry_class: Entry, provider_method: :job_kinds
    )

    def self.entries = REGISTRY.entries
    def self.by_kind = REGISTRY.by_key

    module_function

    def values
      by_kind.keys.freeze
    end

    def infrastructure_values
      entries.select(&:infrastructure).map(&:kind).freeze
    end

    def user_facing_values
      (values - infrastructure_values).freeze
    end

    def issueless_values
      entries.select(&:issueless).map(&:kind).freeze
    end

    def issueless?(kind)
      issueless_values.include?(kind.to_s)
    end
  end
end
