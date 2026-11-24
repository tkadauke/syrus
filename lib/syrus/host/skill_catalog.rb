module Syrus
  module Host
    # Resolves, validates and renders named skills for plugins that fire them
    # (for example scheduled tasks). Reads core on every call; the skill
    # loaders and markdown parser are not exposed.
    module SkillCatalog
      class << self
        # The pattern a skill name must match.
        def name_pattern = Skills::NAME_PATTERN

        # Resolves a skill by name for a repository and user. Raises one of
        # #resolution_errors when it cannot be resolved.
        def resolve(repository:, name:, user: nil) = Skills.for(repository:, name:, user:)

        # Validates arguments against a resolution's declared parameters.
        # Raises one of #argument_errors when they do not match.
        def validate_arguments!(resolution, args)
          Skills::ParameterSchema.validate!(resolution.definition.parameters, args)
        end

        # Renders a resolution's skill body with the given arguments.
        def render(resolution, args) = Skills::Renderer.render(resolution.definition, args)

        # Error classes raised while resolving or parsing a skill.
        def resolution_errors
          [ Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError ]
        end

        # Error classes raised when arguments do not satisfy a skill's parameters.
        def argument_errors = [ Skills::ParameterSchema::ValidationError ]
      end
    end
  end
end
