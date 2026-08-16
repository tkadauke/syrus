require "yaml"

module Skills
  # Parses a SKILL.md file's contents (YAML frontmatter + markdown body)
  # into a Skills::Definition. Same on-disk convention as the
  # contributor-facing `.claude/skills/*/SKILL.md` files already in this
  # repo (frontmatter + instructions) — but a distinct concept driving a
  # different system; see the module doc on Skills for why the two must
  # not be conflated.
  module SkillMarkdown
    FRONTMATTER_PATTERN = /\A---\n(.*?\n)---\n?(.*)\z/m

    ParseError = Class.new(StandardError)

    module_function

    # `name:` is the skill name the caller resolved this file by (the
    # `<name>` segment of `.syrus/skills/<name>/SKILL.md`). When the
    # frontmatter also declares a `name:`, it must match — catches a
    # copy-pasted SKILL.md left with the wrong name.
    #
    # Raises ParseError for malformed frontmatter, or
    # ParameterSchema::ParseError if the declared `parameters:` don't
    # match the schema shape.
    def parse(contents, name: nil)
      match = FRONTMATTER_PATTERN.match(contents.to_s)
      raise ParseError, "SKILL.md must start with a YAML frontmatter block (---...---)" unless match

      raw = YAML.safe_load(match[1]) || {}
      raise ParseError, "SKILL.md frontmatter must be a mapping" unless raw.is_a?(Hash)

      frontmatter_name = raw["name"].to_s.strip.presence
      if frontmatter_name && name && frontmatter_name != name
        raise ParseError, "SKILL.md frontmatter name #{frontmatter_name.inspect} does not match requested skill #{name.inspect}"
      end

      description = raw["description"].to_s.strip
      raise ParseError, "SKILL.md frontmatter.description: is required" if description.empty?

      Definition.new(
        name: frontmatter_name || name,
        description: description,
        parameters: ParameterSchema.normalize(raw["parameters"] || []),
        instructions: match[2].to_s.strip
      )
    rescue Psych::SyntaxError => e
      raise ParseError, "YAML parse error: #{e.message}"
    end
  end
end
