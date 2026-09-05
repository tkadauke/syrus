module VideoWalkthroughs::Prompts
  # The instruction sent to GEMINI when re-analyzing a single CLIP of an
  # already-uploaded walkthrough — the "zoom in" path. Unlike the whole-video
  # pass, this runs at full resolution over a narrow window, so it can read
  # small on-screen text and fast action the first pass may have garbled.
  # `focus` is the caller's specific ask (e.g. "the exact error text", "the
  # sequence of clicks"); `clock_range` is a human "mm:ss–mm:ss" for context.
  class Segment
    RESPONSE_SCHEMA = {
      type: "object",
      properties: {
        findings: {
          type: "string",
          description: "The direct answer to the focus, grounded strictly in what this clip shows and says. If the clip doesn't contain the answer, say so plainly."
        },
        exact_text: {
          type: "array",
          items: { type: "string" },
          description: "Verbatim on-screen text relevant to the focus — error messages, labels, field values, numbers — read carefully at full resolution."
        },
        steps: {
          type: "array",
          items: { type: "string" },
          description: "The ordered sequence of user actions in this clip, if relevant to the focus."
        },
        transcript: {
          type: "array",
          description: "Narration within this clip, timestamped (mm:ss from the clip start), verbatim-ish.",
          items: {
            type: "object",
            properties: {
              timestamp: { type: "string", description: "mm:ss from the start of THIS clip" },
              text: { type: "string" }
            },
            required: %w[timestamp text]
          }
        }
      },
      required: %w[findings]
    }.freeze

    def initialize(focus:, clock_range: nil)
      @focus = focus.to_s.strip
      @clock_range = clock_range
    end

    def to_s
      <<~PROMPT
        You are re-examining a SHORT CLIP#{@clock_range ? " (#{@clock_range})" : ''} of a
        longer screen-recording walkthrough, at full resolution. Focus narrowly
        on this request:

        #{@focus.presence || 'Describe exactly what happens in this clip.'}

        Read small on-screen text carefully — capture exact wording, numbers,
        and error messages verbatim in `exact_text`. Note the precise sequence
        of user actions in `steps`. Listen to the narration and quote the
        user's exact words when they bear on the focus. Report ONLY what is
        actually shown or said in this clip; if the clip does not contain the
        answer, say so plainly in `findings`. Timestamps are mm:ss from the
        start of this clip.

        Respond with JSON only, matching the provided schema.
      PROMPT
    end
  end
end
