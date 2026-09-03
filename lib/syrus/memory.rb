module Syrus
  # Core's side of the `memory_store` extension point.
  #
  # Every core caller that wants agent memory goes through here, so "no
  # memory store is registered" is an ordinary, quiet state -- empty context,
  # no instructions -- rather than a NameError on a plugin constant. A
  # provider that raises is logged and treated the same way: a broken memory
  # store degrades the prompt, it does not fail the run.
  module Memory
    module_function

    def store
      Syrus::PluginRegistry.providers_for(:memory_store).first
    end

    def available?
      store.present?
    end

    def prompt_context(user:, repository_ids:)
      ask(:prompt_context, "", user: user, repository_ids: Array(repository_ids).compact).to_s
    end

    def chat_context_lines(user:, repository_ids:, byte_budget:)
      Array(ask(:chat_context_lines, [], user: user, repository_ids: Array(repository_ids).compact, byte_budget: byte_budget))
    end

    def chat_instructions
      ask(:chat_instructions, "").to_s
    end

    def ask(method, fallback, **kwargs)
      provider = store
      return fallback unless provider.respond_to?(method)

      if kwargs.empty?
        provider.public_send(method)
      else
        provider.public_send(method, **kwargs)
      end
    rescue StandardError => e
      Rails.logger.error("[Syrus::Memory] #{provider}.#{method} failed: #{e.class}: #{e.message}")
      fallback
    end
  end
end
