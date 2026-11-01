require "json"

module Prompts
  class AuthorizationContinuation
    def initialize(payload)
      @payload = payload
    end

    def to_s
      <<~PROMPT.strip
        Continue from the authorization checkpoint below in a fresh agent turn. Treat the supplied tool result or denial as the exact result of the interrupted tool call; do not execute that call again.

        #{JSON.pretty_generate(@payload)}
      PROMPT
    end
  end
end
