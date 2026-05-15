module Prompts
  # Prompt for a direct Job created directly by the operator with a
  # free-form prompt. Unlike issue Jobs (which fetch the title+body from
  # GitHub) or cron Jobs (which wrap a standing instruction in a preamble),
  # direct Jobs carry the operator's prompt as-is — just append the
  # standard safety and submit-summary footers.
  class DirectJob
    def initialize(prompt:)
      @prompt = prompt
    end

    def to_s
      [ @prompt.strip, GitSafety::TEXT, SubmitSummaryInstructions::TEXT ].join("\n\n")
    end
  end
end
