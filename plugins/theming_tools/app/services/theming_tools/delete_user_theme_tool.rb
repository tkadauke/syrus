require "mcp"

module ThemingTools
  # Deletes one of the current user's own custom themes. Refuses built-in
  # themes and other users' themes outright. If the theme being deleted is
  # the user's currently active theme, falls back to their default built-in
  # theme first so color_theme_id never dangles.
  class DeleteUserThemeTool < MCP::Tool
    tool_name "delete_user_theme"

    description "Delete one of the current user's own custom themes. Refuses to delete built-in themes. If the " \
      "theme being deleted is the user's currently active theme, falls back to the default built-in theme first."

    input_schema(
      properties: {
        theme_id: { type: "integer", description: "Id of one of your own custom themes." }
      },
      required: [ "theme_id" ]
    )

    class << self
      def call(theme_id:, server_context:)
        user = server_context.fetch(:chat_session).user
        theme = Theme.find_by(id: theme_id)
        return Mcp::Tools.invalid("No theme with id #{theme_id} was found.") unless theme
        return Mcp::Tools.invalid("Built-in themes can't be deleted.") if theme.built_in?
        return Mcp::Tools.invalid("You can only delete your own themes.") unless theme.owner_user_id == user.id

        fallback = nil
        if user.color_theme_id == theme.id
          fallback = Theme.terracotta
          user.update!(color_theme: fallback)
        end

        theme.destroy!
        Mcp::Tools.success(deleted_theme_id: theme.id, fallback_theme_id: fallback&.id)
      end
    end
  end
end
