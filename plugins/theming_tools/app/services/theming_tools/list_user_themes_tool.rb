require "mcp"

module ThemingTools
  # Lists the current user's own custom (non-built-in) themes -- draft
  # previews and anything they've installed from a full token payload.
  # Built-in themes aren't included; those are covered by the theme picker.
  class ListUserThemesTool < MCP::Tool
    tool_name "list_user_themes"

    description "List the current user's own custom (non-built-in) themes, including any in-progress " \
      "preview drafts. Each theme's `tokens` includes the 13 light/dark color keys plus every non-color " \
      "shape/shadow/spacing/density/typography group, already defaulted (Theme::DEFAULT_EXTENDED_TOKENS) for " \
      "any group the theme never overrode."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        user = server_context.fetch(:chat_session).user
        themes = Theme.where(owner_user: user, built_in: false).order(:name)

        Mcp::Tools.success(themes: themes.map(&:public_payload))
      end
    end
  end
end
