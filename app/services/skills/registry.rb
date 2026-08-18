module Skills
  # Built-in tier of the skill resolver (Skills.for). Single source for
  # built-in skill metadata — same discipline CLAUDE.md documents for
  # Workflow::TriggerKind / Step::Kind ("the single source for
  # trigger/step metadata... add new kinds there instead of scattering
  # constants in helpers/services"), applied here to the built-in
  # Skills:: PORO classes rather than an ActiveRecord-backed model.
  #
  # `klass` is stored as a string and constantized lazily (not a bare
  # class reference) to match Workflow::TriggerKind#template_class /
  # Step::Kind::Entry#handler_class — avoids eager-referencing autoloaded
  # constants at registry-definition time.
  module Registry
    Entry = Data.define(:name, :klass) do
      def klass_const
        "Skills::#{klass}".constantize
      end
    end

    ENTRIES = [
      Entry.new(name: "investigate", klass: "Investigate"),
      Entry.new(name: "onboard-to-syrus", klass: "OnboardToSyrus"),
      Entry.new(name: "debug", klass: "Debug"),
      Entry.new(name: "dependency-audit", klass: "DependencyAudit"),
      Entry.new(name: "explain-failing-ci", klass: "ExplainFailingCi"),
      Entry.new(name: "coverage-gap-report", klass: "CoverageGapReport"),
      Entry.new(name: "dead-code-sweep", klass: "DeadCodeSweep"),
      Entry.new(name: "license-audit", klass: "LicenseAudit"),
      Entry.new(name: "security-review", klass: "SecurityReview")
    ].freeze

    BY_NAME = ENTRIES.index_by(&:name).freeze

    module_function

    def values
      BY_NAME.keys.freeze
    end

    def fetch(name)
      BY_NAME.fetch(name.to_s) do
        raise NotFoundError, "unknown built-in skill name=#{name.inspect}"
      end
    end

    def class_for(name)
      fetch(name).klass_const
    end

    def definition_for(name, workspace_path: nil, args: {}, repository: nil)
      class_for(name).definition(workspace_path: workspace_path, args: args, repository: repository)
    end
  end
end
