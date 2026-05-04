module Prompts
  # Prompt for an ad hoc Job created directly by the operator with a
  # free-form prompt. Unlike issue Jobs (which fetch the title+body from
  # GitHub) or cron Jobs (which wrap a standing instruction in a preamble),
  # ad hoc Jobs carry the operator's prompt as-is — just append the
  # standard safety and submit-summary footers.
  class AdhocJob
    def initialize(prompt:)
      @prompt = prompt
    end

    def to_s
      [ @prompt.strip, GitSafety::TEXT, SubmitSummaryInstructions::TEXT ].join("\n\n")
    end
  end
end
