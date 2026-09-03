module AgentMemory
  # Core does not own memories, so User does not declare this association.
  module HostAssociations
    def self.apply!
      return if User.reflect_on_association(:agent_memories)

      User.has_many :agent_memories,
                    class_name: "AgentMemory::Entry",
                    foreign_key: :user_id,
                    inverse_of: :user,
                    dependent: :destroy
    end
  end
end
