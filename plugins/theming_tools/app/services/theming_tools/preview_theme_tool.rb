require "mcp"

module ThemingTools
  # Drafts a candidate theme and pops it open for the user against the
  # real Style Guide page (app/frontend/routes/DesignSystem.tsx), so token
  # choices can be judged against actual components instead of a mockup.
  #
  # Upserts one draft Theme row per user (found by a deterministic per-user
  # slug, not by name) so repeat calls in the same chat -- the expected way
  # an agent iterates on a palette -- update that same row instead of
  # littering the themes table with one row per call. Any token key left out
  # of `light`/`dark` falls back to the user's currently active theme, so the
  # agent can tweak just a couple of values at a time. The same partial-
  # override merge applies to the non-color Theme::EXTENDED_TOKEN_GROUPS
  # (shape/shadow/spacing/density/typography, see ExtendedTokenSchema) --
  # an omitted group or key falls back to the active theme's own value, then
  # to Theme::DEFAULT_EXTENDED_TOKENS, so a draft that never touches shape
  # or density still previews and installs cleanly.
  #
  # Runs the same Theme#contrast_issues WCAG AA check install_theme/
  # update_user_theme enforce, but never blocks on it -- drafts are
  # explicitly meant to support fast iteration through invalid intermediate
  # states (e.g. mid-edit on one token pair). Any failing pairs come back as
  # a non-blocking `contrast_warnings` array so the agent (and the live
  # preview panel) can flag them early, before the user reaches install time.
  class PreviewThemeTool < MCP::Tool
    tool_name "preview_theme"

    description "Draft a candidate theme and open a live preview of it in the user's chat, rendered " \
      "against the real Style Guide page so token choices can be judged on actual components. Accepts a " \
      "display name, any subset of the 13 color token keys for light and dark mode (brand, brand-emphasis, " \
      "surface, surface-raised, border, text-primary, text-secondary, success, warning, danger, info, " \
      "neutral, on-brand), and any subset of the non-color token groups -- shape (radius-control, " \
      "radius-panel, radius-pill, border-width), shadow (shadow-panel), spacing (space-page-x, space-page-y, " \
      "space-section, space-section-compact), density (control-height-sm, control-height-md, " \
      "table-row-height), and typography (font-sans, font-mono, text-page-title, text-section-title, " \
      "text-body, text-caption) -- any token or group you omit defaults to the user's currently active theme " \
      "(non-color tokens fall further back to Syrus's built-in defaults), so you can iterate on just a " \
      "couple of values at a time, color or otherwise. Safe to call repeatedly: each call updates the same " \
      "draft theme in place instead of creating a new row. Runs the same WCAG AA contrast check install_theme " \
      "enforces (color tokens only) and returns any failing pairs as a non-blocking `contrast_warnings` " \
      "array -- the draft still saves either way."

    TOKEN_PROPERTIES = Theme::TOKEN_KEYS.index_with do |_key|
      { type: "string", description: "CSS color value, e.g. a hex code." }
    end

    input_schema(
      properties: {
        name: { type: "string", description: "Display name for the draft theme." },
        light: { type: "object", description: "Light-mode color token overrides.", properties: TOKEN_PROPERTIES },
        dark: { type: "object", description: "Dark-mode color token overrides.", properties: TOKEN_PROPERTIES },
        **ExtendedTokenSchema::GROUP_PROPERTIES
      },
      required: [ "name" ]
    )

    class << self
      def call(name:, server_context:, light: nil, dark: nil, shape: nil, shadow: nil, spacing: nil, density: nil, typography: nil)
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
        }.merge(ExtendedTokenSchema.merge_groups(baseline, shape: shape, shadow: shadow, spacing: spacing, density: density, typography: typography))

        if theme.save
          broadcast_preview(chat_session, theme)
          Mcp::Tools.success(
            theme_id: theme.id,
            name: theme.name,
            tokens: theme.tokens,
            contrast_warnings: theme.contrast_warning_messages
          )
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
