module Prompts
  # The rendered instructions for a `/skill-name key=value ...` slash
  # command, executed inline as the current turn of an already-Coding-Mode
  # chat (see Skills::ChatInvocation, which gates on Coding Mode before this
  # ever gets built). Prompts::ChatCodingMode, appended separately by
  # ChatTurnJob's coding_mode_guidance, already covers checkout mechanics
  # and the handoff tools; this only frames what the agent's task for this
  # turn is and restates the two valid outcomes so the agent doesn't invent
  # a diff just to have something to hand off.
  class ChatSkillInvocation
    def initialize(resolution:, args:)
      @resolution = resolution
      @args = args
    end

    def to_s
      [ header, instructions, footer ].join("\n\n")
    end

    private

    def header
      "The operator invoked the `/#{@resolution.definition.name}` skill via slash command."
    end

    def instructions
      Skills::Renderer.render(@resolution.definition, @args)
    end

    def footer
      <<~TEXT.strip
        This is your task for this turn. If it calls for code changes, make them
        directly in the coding checkout and commit as usual — the normal Coding
        Mode handoff (`complete_implement_step` / `submit_coding_changes`, still
        requiring operator confirmation before any Job or PR is created) applies
        exactly as it would for any other Coding Mode change. If this skill is
        read-only or otherwise produces no diff, that is a complete, successful
        outcome — just report your findings in this chat; there is nothing
        further to confirm.
      TEXT
    end
  end
end
