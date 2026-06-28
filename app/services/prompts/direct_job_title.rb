module Prompts
  class DirectJobTitle
    def initialize(prompt:, repository:)
      @prompt = prompt
      @repository = repository
    end

    def to_s
      <<~PROMPT
        Name this Syrus direct Job from the operator's request.

        Return only JSON in this exact shape:
        {"title":"Short job title"}

        Rules:
        - Interpret what the operator wants Syrus to build or change.
        - Use a concise task-style title, not a full sentence.
        - Maximum 60 characters.
        - Do not include quotes, markdown, repository names, or filler like "Direct job".
        - If the request is too vague to name, return {"title":""}.

        Repository:
        #{repository_label}

        Operator request:
        #{@prompt.to_s.strip}
      PROMPT
    end

    private

    def repository_label
      @repository&.slug.presence || "(none)"
    end
  end
end
