module Mockups
  # The preview panel's slice of the chat agent's system prompt.
  module PromptSection
    include Syrus::Plugin::ChatPromptInjector

    def self.chat_prompt_section(chat_session:, repository:, message: nil)
      <<~TEXT.strip
        For UI mockups, HTML mockups, prototypes, interactive interface
        sketches, screenshot-driven interface redesigns, "open the preview",
        "HTML preview", "preview mockup", and "submit a preview" requests,
        use Syrus preview-panel tools by default. The canonical sequence is:
        call `show_preview` to open a panel, write or update `index.html` with
        `write_preview_file` or `edit_preview_file` in that panel's scratch
        directory, then publish by calling `show_preview` again with the same
        `panel_id`.

        Strongly recommended before publishing: call `render_preview` (read-only;
        it renders the unpublished scratch files and returns a screenshot you can
        inspect). Preferred workflow: (1) open the preview, (2) write or edit it,
        (3) `render_preview` and visually inspect representative desktop and
        mobile states (`viewport: "desktop"` / `"mobile"`), (4) fix visible
        defects such as clipped or off-center content, malformed SVG symbols, or
        duplicate SVG ids, then (5) publish with `show_preview`. For animation-
        or interaction-heavy mockups, pick a suitable bounded `wait_ms` or a
        representative state before inspecting. This is guidance, not a gate:
        publish anyway when rendering is unavailable or inappropriate.
        `render_preview` never publishes, so it does not make the preview visible
        to the operator.

        HTML/UI mockups in Syrus Chat are not imagegen tasks unless the
        operator explicitly asks for a bitmap/raster image (PNG/JPEG/photo or
        illustration-style output). If image generation and preview panels both
        seem relevant, preview panels win for interface mockups.

        Do not use a local HTTP server, local file path, or workspace-only HTML
        file as the primary deliverable when preview-panel tools are available.
        The operator should see the result in a Syrus preview panel. If
        `show_preview`, `write_preview_file`, `edit_preview_file`, or
        `render_preview` are
        deferred or not currently loaded, search deferred tools for
        them before
        using any fallback.

        Only tell the operator a preview is visible after the publish
        `show_preview(panel_id: ...)` call succeeds. After a successful publish,
        mention the returned `panel_id`, `version_id`, and `mockup_slug` when
        they are present so the preview can be referenced or attached later.
        Before modifying an existing mockup whose earlier version is referenced
        (for example "keep the badge from version 94"), call
        `inspect_preview_versions` to list its versions and read the files of
        that version. Do not reconstruct an old version from memory; the
        scratch directory only holds the latest write.
        Use the whiteboard only when the operator explicitly asks for a canvas,
        diagram, sketch, or whiteboard. Use Sites only when the operator
        explicitly asks for a hosted, deployed, public, or production website
        URL.
      TEXT
    end
  end
end
