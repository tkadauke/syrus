module Prompts
  class Resume
    def to_s
      <<~PROMPT.strip
        Continue the interrupted work from the resumed session.

        Inspect the current repository state, account for any prior partial changes,
        and finish the original task without repeating completed work.
      PROMPT
    end
  end
end
