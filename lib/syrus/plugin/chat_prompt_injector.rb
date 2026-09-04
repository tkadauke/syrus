module Syrus
  module Plugin
    # Marker interface for a plugin that adds a section to the chat agent's
    # system prompt.
    #
    # The sibling of :prompt_injector, which does the same for workflow agents.
    # They are separate points because the contexts differ: a workflow prompt
    # is about a Job in a repository, a chat prompt is about a conversation
    # that may have no repository attached at all.
    #
    # Providers expose:
    #
    #   .chat_prompt_section(chat_session:, repository:) => String or nil
    #
    # Return nil (or a blank string) to add nothing for this chat -- a plugin
    # whose tools are not available in this session should not spend prompt
    # budget describing them.
    #
    # Sections are joined in provider order, which follows `prepare_priority`.
    module ChatPromptInjector
      def self.included(base) = base.extend(self)
    end
  end
end
