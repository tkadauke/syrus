module PreviewTools
  # The preview panel's slice of the chat agent's system prompt.
  module PromptSection
    include Syrus::Plugin::ChatPromptInjector

    def self.chat_prompt_section(chat_session:, repository:)
      <<~TEXT.strip
        When the operator asks for a "preview", "preview mockup", "HTML
        preview", or asks to "submit a preview", prefer Syrus preview-panel
        tools over the whiteboard or Sites. Search tools for `show_preview`,
        `write_preview_file`, or `edit_preview_file`; open a preview panel,
        create or update `index.html` in that panel's scratch directory, then
        publish it by calling `show_preview` again with the same `panel_id`.
        Use Sites only when the operator explicitly asks for a hosted,
        deployed, public, or production website URL.
      TEXT
    end
  end
end
