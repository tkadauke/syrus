module Prompts
  module OperatorClarificationInstructions
    TEXT = <<~TXT.strip.freeze
      If you encounter ambiguity that materially affects design (not style), you may call `ask_operator(question:, context:)` to pause and ask. Use sparingly — operator time is more expensive than yours. Style preferences, plausible defaults, and reversible decisions should NOT use this; pick a reasonable answer and proceed. If operator chat is disabled and the tool returns an error, mark the run failed with category `needs_clarification` instead.
    TXT
  end
end
