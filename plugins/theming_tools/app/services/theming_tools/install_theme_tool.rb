require "mcp"

module ThemingTools
  # Persists a candidate theme (usually one already shown via preview_theme)
  # as the calling user's active color_theme. Guards against illegible
  # palettes: runs Theme#contrast_issues first and rejects with a specific,
  # per-pair fix-it message instead of silently installing something users
  # can't read.
  class InstallThemeTool < MCP::Tool
    tool_name "install_theme"

    description "Install a color theme as the current user's active theme. Accepts either theme_id (a theme " \
      "from a prior preview_theme call, or any built-in/owned theme) or a full token payload (name + complete " \
      "light/dark hashes covering all 13 token keys). Runs a WCAG AA contrast check first and rejects with a " \
      "specific message (which pair, the actual ratio, the required ratio) instead of installing an illegible " \
      "palette."

    TOKEN_PROPERTIES = Theme::TOKEN_KEYS.index_with do |_key|
      { type: "string", description: "CSS color value, e.g. a hex code." }
    end

    input_schema(
      properties: {
        theme_id: { type: "integer", description: "Id of an existing theme (from preview_theme, or any built-in/owned theme) to install." },
        name: { type: "string", description: "Display name for a new theme, when not using theme_id." },
        light: { type: "object", description: "Complete light-mode token set, when not using theme_id.", properties: TOKEN_PROPERTIES },
        dark: { type: "object", description: "Complete dark-mode token set, when not using theme_id.", properties: TOKEN_PROPERTIES }
      },
      required: []
    )

    class << self
      def call(server_context:, theme_id: nil, name: nil, light: nil, dark: nil)
        user = server_context.fetch(:chat_session).user

        theme, error = resolve_theme(user, theme_id: theme_id, name: name, light: light, dark: dark)
        return Mcp::Tools.invalid(error) if error

        issues = theme.contrast_issues
        return Mcp::Tools.invalid(rejection_message(issues)) if issues.any?

        if theme.new_record?
          theme.owner_user = user
          theme.built_in = false
        end

        if theme.save
          user.update!(color_theme: theme)
          Mcp::Tools.success(theme.public_payload)
        else
          Mcp::Tools.invalid(theme.errors.full_messages.to_sentence)
        end
      end

      private

      def resolve_theme(user, theme_id:, name:, light:, dark:)
        if theme_id.present?
          theme = Theme.selectable_by(user).find_by(id: theme_id)
          return [ nil, "No theme with id #{theme_id} is available to you." ] unless theme

          [ theme, nil ]
        elsif name.present? && light.present? && dark.present?
          [ Theme.new(name: name, slug: unique_slug_for(user, name), tokens: { "light" => light, "dark" => dark }), nil ]
        else
          [ nil, "Provide either theme_id (from a prior preview_theme call) or name, light, and dark." ]
        end
      end

      def unique_slug_for(user, name)
        base = name.to_s.parameterize.presence || "theme"
        candidate = "#{base}-#{user.id}"
        suffix = 1
        while Theme.exists?(slug: candidate)
          suffix += 1
          candidate = "#{base}-#{user.id}-#{suffix}"
        end
        candidate
      end

      def rejection_message(issues)
        "Contrast check failed -- fix these before installing: #{issues.map { |issue| issue.fetch(:message) }.join('; ')}."
      end
    end
  end
end
