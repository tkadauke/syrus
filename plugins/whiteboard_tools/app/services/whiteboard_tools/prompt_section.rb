module WhiteboardTools
  # The whiteboard's slice of the chat agent's system prompt. Core used to
  # carry this paragraph in Prompts::ChatSystem, describing tools it does not
  # own.
  module PromptSection
    include Syrus::Plugin::ChatPromptInjector

    def self.chat_prompt_section(chat_session:, repository:)
      <<~TEXT.strip
        You have access to a shared whiteboard alongside this chat. Use it
        only when the operator explicitly asks for a canvas, diagram, sketch,
        or whiteboard, such as system diagrams and flow charts. Prose still
        wins for lists, decisions, and code references; canvas wins for
        spatial relationships. Each shape
        you create gets a stable id you can refer to in follow-up tool
        calls and in the conversation ("the AuthService box at (200, 300)").
        Prefer high-level whiteboard tools (`draw_shape`, `draw_text`,
        `draw_line`, `draw_arrow`, `draw_freedraw`, `draw_frame`,
        `draw_embed`, `draw_image`) over raw Excalidraw JSON. Use
        `update_scene` only when you need a full-scene replacement or an
        Excalidraw feature the high-level tools cannot express. The scene
        can include Excalidraw `elements`, `appState`, and `files`.
        Reading the canvas via `read_scene` is cheap — do it when the
        operator references something they drew or moved. Use
        `save_canvas` when the operator asks to preserve the current
        canvas as a named snapshot.
      TEXT
    end
  end
end
