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
        # Plugin-contributed entries carry a fully qualified constant name.
        (klass.include?("::") ? klass : "Skills::#{klass}").constantize
      end
    end

    ENTRIES = [
      Entry.new(name: "investigate", klass: "Investigate"),
      Entry.new(name: "investigate-and-report", klass: "InvestigateAndReport"),
      Entry.new(name: "onboard-to-syrus", klass: "OnboardToSyrus"),
      Entry.new(name: "debug", klass: "Debug"),
      Entry.new(name: "rebase-conflict-resolver", klass: "RebaseConflictResolver"),
      Entry.new(name: "dependency-audit", klass: "DependencyAudit"),
      Entry.new(name: "explain-failing-ci", klass: "ExplainFailingCi"),
      Entry.new(name: "dead-code-sweep", klass: "DeadCodeSweep"),
      Entry.new(name: "license-audit", klass: "LicenseAudit"),
      Entry.new(name: "security-review", klass: "SecurityReview"),
      Entry.new(name: "add-ci-workflow", klass: "AddCiWorkflow"),
      Entry.new(name: "init-docs", klass: "InitDocs"),
      Entry.new(name: "changelog-generate", klass: "ChangelogGenerate")
    ].freeze

    BY_NAME = ENTRIES.index_by(&:name).freeze

    module_function

    def values
      by_name.keys.freeze
    end

    def fetch(name)
      by_name.fetch(name.to_s) do
        raise NotFoundError, "unknown built-in skill name=#{name.inspect}"
      end
    end

    # Built-ins plus the skills enabled :skill plugins contribute. A plugin
    # cannot shadow a skill the host defines; the entry is dropped and logged.
    def by_name
      plugin_entries.each_with_object(BY_NAME.dup) do |entry, merged|
        if merged.key?(entry.name)
          Rails.logger.warn("[Skills::Registry] ignoring plugin skill #{entry.name.inspect}: name is already registered")
        else
          merged[entry.name] = entry
        end
      end
    end

    def plugin_entries
      Syrus::PluginRegistry.providers_for(:skill).flat_map do |provider|
        result = Syrus::PluginInvocation.call(
          extension_point: :skill, provider:, operation: :skill_entries, on_decline: []
        ) { provider.skill_entries }
        Array(Syrus::PluginInvocation.value(result)).map do |attributes|
          attributes = attributes.to_h.symbolize_keys
          Entry.new(name: attributes.fetch(:name).to_s, klass: attributes.fetch(:klass).to_s)
        end
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
