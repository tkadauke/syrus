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

      # `workspace_path` is present only when the caller already has a
      # real checkout on disk (currently: Steps::RunSkill, once the
      # Workflow's shared workspace is set up) — nil everywhere else
      # (the skill picker, chat slash-command listing, ScheduledTask
      # fire). Most skills ignore it entirely; a skill that wants to
      # tailor its instructions to the actual repo (see
      # Skills::OnboardToSyrus) can read it from `@workspace_path`.
      def definition(workspace_path: nil)
        Definition.new(
          name: skill_name,
          description: description,
          parameters: ParameterSchema.normalize(parameter_schema),
          instructions: new(workspace_path: workspace_path).to_s
        )
      end
    end

    def initialize(workspace_path: nil)
      @workspace_path = workspace_path
    end

    def to_s
      raise NotImplementedError, "#{self.class} must implement #to_s"
    end
  end
end
