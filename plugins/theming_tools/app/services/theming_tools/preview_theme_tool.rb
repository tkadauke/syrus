require "mcp"

module ThemingTools
  # Drafts a candidate color theme and pops it open for the user against the
  # real Style Guide page (app/frontend/routes/DesignSystem.tsx), so token
  # choices can be judged against actual components instead of a mockup.
  #
  # Upserts one draft Theme row per user (found by a deterministic per-user
  # slug, not by name) so repeat calls in the same chat -- the expected way
  # an agent iterates on a palette -- update that same row instead of
  # littering the themes table with one row per call. Any token key left out
  # of `light`/`dark` falls back to the user's currently active theme, so the
  # agent can tweak just a couple of values at a time.
  class PreviewThemeTool < MCP::Tool
    tool_name "preview_theme"

    description "Draft a candidate color theme and open a live preview of it in the user's chat, rendered " \
      "against the real Style Guide page so token choices can be judged on actual components. Accepts a " \
      "display name plus any subset of the 13 token keys for light and dark mode (brand, brand-emphasis, " \
      "surface, surface-raised, border, text-primary, text-secondary, success, warning, danger, info, " \
      "neutral, on-brand) -- any token you omit defaults to the user's currently active theme, so you can " \
      "iterate on just a couple of values at a time. Safe to call repeatedly: each call updates the same " \
      "draft theme in place instead of creating a new row."

    TOKEN_PROPERTIES = Theme::TOKEN_KEYS.index_with do |_key|
      { type: "string", description: "CSS color value, e.g. a hex code." }
    end

    input_schema(
      properties: {
        name: { type: "string", description: "Display name for the draft theme." },
        light: { type: "object", description: "Light-mode token overrides.", properties: TOKEN_PROPERTIES },
        dark: { type: "object", description: "Dark-mode token overrides.", properties: TOKEN_PROPERTIES }
      },
      required: [ "name" ]
    )

    class << self
      def call(name:, server_context:, light: nil, dark: nil)
        chat_session = server_context.fetch(:chat_session)
        user = chat_session.user
        baseline = user.color_theme&.tokens || {}

        theme = Theme.find_or_initialize_by(slug: draft_slug(user))
        theme.owner_user = user
        theme.built_in = false
        theme.name = name
        theme.tokens = {
          "light" => merged_tokens(baseline, "light", light),
          "dark" => merged_tokens(baseline, "dark", dark)
        }

        if theme.save
          broadcast_preview(chat_session, theme)
          Mcp::Tools.success(theme_id: theme.id, name: theme.name, tokens: theme.tokens)
        else
          Mcp::Tools.invalid(theme.errors.full_messages.to_sentence)
        end
      end

      private

      def draft_slug(user)
        "preview-draft-#{user.id}"
      end

      def merged_tokens(baseline, mode, overrides)
        base = baseline[mode] || {}
        supplied = (overrides || {}).stringify_keys
        Theme::TOKEN_KEYS.index_with { |key| supplied[key].presence || base[key] }.compact
      end

      def broadcast_preview(chat_session, theme)
        AppEvents.broadcast(
          user: theme.owner_user,
          type: "updated",
          resource: "chat",
          id: chat_session.id,
          payload: {
            action: "open_theme_preview",
            theme_id: theme.id,
            path: "/design_system?theme_id=#{theme.id}"
          }
        )
      end
    end
  end
end
