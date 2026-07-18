class MemoryPolicy
  # Capability name constants for memory read/write access.
  MEMORY_READ              = "memory:read"
  MEMORY_WRITE_USER        = "memory:write:user"
  MEMORY_WRITE_REPOSITORY  = "memory:write:repository"
  MEMORY_WRITE_TEAM        = "memory:write:team"
  MEMORY_WRITE_INSTANCE    = "memory:write:instance"
  MEMORY_WRITE_INSIGHT     = "memory:write:insight"

  CONTEXT_READ_GLOBAL      = "context:read:global"
  CONTEXT_READ_REPOSITORY  = "context:read:repository"
  CONTEXT_READ_TEAM        = "context:read:team"
  CONTEXT_READ_INSTANCE    = "context:read:instance"

  def self.for(context)
    new(context)
  end

  def initialize(context)
    @context = context
  end

  # Stubs hardcoding existing behavior: all reads permitted, write only to
  # user-scoped (global) and repository-scoped memories.
  def permitted_capabilities
    [
      MEMORY_READ,
      MEMORY_WRITE_USER,
      MEMORY_WRITE_REPOSITORY,
      CONTEXT_READ_GLOBAL,
      CONTEXT_READ_REPOSITORY
    ]
  end

  def can?(capability)
    permitted_capabilities.include?(capability)
  end
end
