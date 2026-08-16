module Skills
  # Substitutes a resolved skill's `{{key}}` instruction placeholders
  # (see Skills::Investigate's `{{question}}`) with caller-supplied args,
  # falling back to each parameter's declared default when the caller
  # didn't submit a value. Used by Steps::RunSkill (and any future
  # invocation surface — chat slash command, ScheduledTask — that needs
  # the same rendering). Distinct from `ParameterSchema.validate!`, which
  # only checks the submitted args are well-formed; this module never
  # raises — an undeclared or still-unresolved `{{placeholder}}` is left
  # verbatim rather than silently dropped, so an authoring mistake in a
  # SKILL.md is visible in the rendered prompt instead of vanishing.
  module Renderer
    PLACEHOLDER_PATTERN = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/

    module_function

    def render(definition, args)
      values = effective_values(definition.parameters, args)
      definition.instructions.gsub(PLACEHOLDER_PATTERN) do |match|
        key = Regexp.last_match(1)
        values.key?(key) ? values[key].to_s : match
      end
    end

    def effective_values(parameters, args)
      submitted = (args || {}).stringify_keys
      parameters.each_with_object({}) do |field, values|
        value = submitted.key?(field.key) ? submitted[field.key] : field.default
        values[field.key] = value unless value.nil?
      end
    end
  end
end
