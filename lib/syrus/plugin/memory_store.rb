module Syrus
  module Plugin
    # Interface for the durable memory an agent carries between runs.
    #
    # Memory used to be `ChatMemory` plus nine MCP tools plus seven prompt
    # injection sites, all core -- which made "remember things" a fixed part
    # of what Syrus is rather than a choice. This extension point makes the
    # store *swappable*, not merely optional: core prompts ask whoever is
    # registered for their context and render nothing when nobody is, so a
    # different implementation (a vector store, a hosted memory service) can
    # take over by registering here.
    #
    # Providers implement, at the class level:
    #
    #   # Memory context appended to an implementing agent's prompt.
    #   def self.prompt_context(user:, repository_ids:) -> String
    #
    #   # Pinned-context lines for a chat's system prompt. `byte_budget` is
    #   # the space the caller has left; a provider must not exceed it.
    #   def self.chat_context_lines(user:, repository_ids:, byte_budget:) -> Array<String>
    #
    #   # The "how to use memory" section of the chat system prompt. The tool
    #   # names belong to whoever provides the tools, so the copy does too.
    #   def self.chat_instructions -> String
    #
    # Every method is optional; a provider that omits one contributes nothing
    # for it. Core reaches the registered provider through `Syrus::Memory`,
    # never directly.
    module MemoryStore
    end
  end
end
