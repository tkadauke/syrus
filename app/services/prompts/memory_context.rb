module Prompts
  # Core's seam onto whatever memory store is registered. Prompts compose
  # this the same way they always did; what it renders now comes from the
  # `memory_store` provider, and is empty when none is registered.
  class MemoryContext
    def initialize(user:, repository_ids:)
      @user = user
      @repository_ids = repository_ids
    end

    def to_s
      return "" unless @user

      Syrus::Memory.prompt_context(user: @user, repository_ids: @repository_ids)
    end
  end
end
