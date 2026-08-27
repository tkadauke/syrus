require "mcp"

module ThemingTools
  # Renames and/or adjusts token values on one of the current user's own
  # custom themes. Re-runs the same contrast check install_theme uses --
  # editing a theme back into illegibility is rejected the same way
  # installing one for the first time would be.
  class UpdateUserThemeTool < MCP::Tool
    tool_name "update_user_theme"

    description "Rename and/or adjust token values on one of the current user's own custom themes. Any token " \
      "you omit from light/dark keeps its current value. Re-runs the WCAG AA contrast check and rejects with a " \
      "specific message if the update would make the theme illegible."

    TOKEN_PROPERTIES = Theme::TOKEN_KEYS.index_with do |_key|
      { type: "string", description: "CSS color value, e.g. a hex code." }
    end

    input_schema(
      properties: {
        theme_id: { type: "integer", description: "Id of one of your own custom themes." },
        name: { type: "string", description: "New display name (optional)." },
        light: { type: "object", description: "Light-mode token overrides (optional; merged with existing values).", properties: TOKEN_PROPERTIES },
        dark: { type: "object", description: "Dark-mode token overrides (optional; merged with existing values).", properties: TOKEN_PROPERTIES }
      },
      required: [ "theme_id" ]
    )

    class << self
      def call(theme_id:, server_context:, name: nil, light: nil, dark: nil)
        user = server_context.fetch(:chat_session).user
        theme = Theme.where(owner_user: user, built_in: false).find_by(id: theme_id)
        return Mcp::Tools.invalid("No custom theme with id #{theme_id} owned by you was found.") unless theme

        theme.name = name if name.present?
        theme.tokens = {
          "light" => merged_tokens(theme.tokens["light"], light),
          "dark" => merged_tokens(theme.tokens["dark"], dark)
        }

        issues = theme.contrast_issues
        return Mcp::Tools.invalid(rejection_message(issues)) if issues.any?

        if theme.save
          Mcp::Tools.success(theme.public_payload)
        else
          Mcp::Tools.invalid(theme.errors.full_messages.to_sentence)
        end
      end

      private

      def merged_tokens(existing, overrides)
        base = existing || {}
        supplied = (overrides || {}).stringify_keys
        Theme::TOKEN_KEYS.index_with { |key| supplied[key].presence || base[key] }.compact
      end

      def rejection_message(issues)
        "Contrast check failed -- fix these before saving: #{issues.map { |issue| issue.fetch(:message) }.join('; ')}."
      end
    end
  end
end
