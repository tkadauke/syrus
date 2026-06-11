module Prompts
  class ChatTitle
    def initialize(message:, repository:)
      @message = message
      @repository = repository
    end

    def to_s
      <<~PROMPT
        Name this Syrus chat from the user's first request.

        Return only JSON in this exact shape:
        {"title":"Short project name"}

        Rules:
        - Interpret what the user wants Syrus to build or change.
        - Use a concise project-style name, not a sentence.
        - Maximum 60 characters.
        - Do not include quotes, markdown, repository names, or filler like "New chat".
        - If the request is too vague to name, return {"title":""}.

        Repository:
        #{repository_label}

        User request:
        #{@message.to_s.strip}
      PROMPT
    end

    private

    def repository_label
      @repository&.slug.presence || "(none)"
    end
  end
end
