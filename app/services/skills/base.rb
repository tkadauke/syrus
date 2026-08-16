module Skills
  # Base class for built-in skills — one PORO per skill under
  # app/services/skills/, registered in Skills::Registry. Mirrors the
  # Prompts:: convention documented in CLAUDE.md: one class per skill,
  # `#to_s` composes the instructions, never inlined elsewhere.
  class Base
    class << self
      # Unique built-in skill name — must match its Skills::Registry entry.
      def skill_name
        raise NotImplementedError, "#{self} must implement .skill_name"
      end

      def description
        raise NotImplementedError, "#{self} must implement .description"
      end

      # Array of { key:, type:, required:, label:, ... } — see
      # Skills::ParameterSchema. Override in subclasses that take params;
      # defaults to none.
      def parameter_schema
        []
      end

      def definition
        Definition.new(
          name: skill_name,
          description: description,
          parameters: ParameterSchema.normalize(parameter_schema),
          instructions: new.to_s
        )
      end
    end

    def to_s
      raise NotImplementedError, "#{self.class} must implement #to_s"
    end
  end
end
