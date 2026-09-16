module ThemingTools
  # Shared JSON-schema fragment and merge logic for Theme::EXTENDED_TOKEN_GROUPS
  # (shape, shadow, spacing, density, typography) -- the non-color token groups
  # layered on top of the original 13-key light/dark color model (see
  # app/models/theme.rb). Reused by preview_theme, install_theme, and
  # update_user_theme so their MCP input_schema properties and partial-override
  # merge behavior for these groups stay in one place instead of drifting
  # across three separate tool files.
  module ExtendedTokenSchema
    GROUP_PROPERTIES = Theme::EXTENDED_TOKEN_GROUPS.each_with_object({}) do |(group, keys), properties|
      properties[group.to_sym] = {
        type: "object",
        description: "Non-color '#{group}' token overrides (#{keys.join(', ')}). Any key you omit keeps its " \
          "current/default value.",
        properties: keys.index_with { { type: "string", description: "CSS value, e.g. a length, font stack, or shadow." } }
      }
    end.freeze

    # Merges any subset of shape/shadow/spacing/density/typography overrides
    # onto `baseline` (a plain tokens hash, e.g. a Theme's raw `tokens` --
    # not the defaulted `tokens_with_defaults` view). Mirrors the light/dark
    # partial-override merge every tool already does: an omitted key keeps
    # the baseline value, and a group with neither a baseline value nor an
    # override is left out of the result entirely so Theme#tokens_with_defaults
    # can fill it in from Theme::DEFAULT_EXTENDED_TOKENS at read time instead
    # of every write baking in the current defaults verbatim.
    def self.merge_groups(baseline, shape: nil, shadow: nil, spacing: nil, density: nil, typography: nil)
      overrides = { "shape" => shape, "shadow" => shadow, "spacing" => spacing, "density" => density, "typography" => typography }

      Theme::EXTENDED_TOKEN_GROUPS.each_with_object({}) do |(group, keys), merged|
        base_group = baseline[group] || {}
        supplied = (overrides[group] || {}).stringify_keys
        group_tokens = keys.index_with { |key| supplied[key].presence || base_group[key] }.compact
        merged[group] = group_tokens if group_tokens.present?
      end
    end
  end
end
