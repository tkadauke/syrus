module Mockups
  # The preview panel's slice of the chat agent's system prompt.
  module PromptSection
    include Syrus::Plugin::ChatPromptInjector

    def self.chat_prompt_section(chat_session:, repository:)
      <<~TEXT.strip
        For UI mockups, HTML mockups, prototypes, interactive interface
        sketches, screenshot-driven interface redesigns, "open the preview",
        "HTML preview", "preview mockup", and "submit a preview" requests,
        use Syrus preview-panel tools by default. The canonical sequence is:
        call `show_preview` to open a panel, write or update `index.html` with
        `write_preview_file` or `edit_preview_file` in that panel's scratch
        directory, then publish by calling `show_preview` again with the same
        `panel_id`.

        HTML/UI mockups in Syrus Chat are not imagegen tasks unless the
        operator explicitly asks for a bitmap/raster image (PNG/JPEG/photo or
        illustration-style output). If image generation and preview panels both
        seem relevant, preview panels win for interface mockups.

        Do not use a local HTTP server, local file path, or workspace-only HTML
        file as the primary deliverable when preview-panel tools are available.
        The operator should see the result in a Syrus preview panel. If
        `show_preview`, `write_preview_file`, or `edit_preview_file` are
        deferred or not currently loaded, search deferred tools for
        `show_preview`, `write_preview_file`, or `edit_preview_file` before
        using any fallback.

        Only tell the operator a preview is visible after the publish
        `show_preview(panel_id: ...)` call succeeds. After a successful publish,
        mention the returned `panel_id`, `version_id`, and `mockup_slug` when
        they are present so the preview can be referenced or attached later.
        Use the whiteboard only when the operator explicitly asks for a canvas,
        diagram, sketch, or whiteboard. Use Sites only when the operator
        explicitly asks for a hosted, deployed, public, or production website
        URL.
      TEXT
    end
  end
end
