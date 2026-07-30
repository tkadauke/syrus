module Syrus
  module Plugin
    # Interface module for prompt injector plugins.
    #
    # Implementing classes (instance-level):
    #   #call(repository:, job:) → String or nil
    module PromptInjector
      # Returns a String to append to the implementing agent's system prompt,
      # or nil to inject nothing for this provider.
      def call(repository:, job:)
        raise NotImplementedError, "#{self.class}#call must return a String or nil"
      end
    end
  end
end
