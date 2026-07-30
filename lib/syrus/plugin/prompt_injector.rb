module Syrus
  module Plugin
    module PromptInjector
      INTERFACE_FOR = :prompt_injector

      # Returns a String to append to the implementing agent's system prompt,
      # or nil to inject nothing for this provider.
      def call(repository:, job:)
        raise NotImplementedError, "#{self.class}#call must return a String or nil"
      end
    end
  end
end
