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
      Entry.new(name: "investigate", klass: "Investigate")
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

    def definition_for(name)
      class_for(name).definition
    end
  end
end
