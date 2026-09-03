module AgentMemory
  # What used to be `User has_many :agent_memories, dependent: :destroy`,
  # injected onto the core model at boot.
  #
  # Registered without a `plugin:` scope: disabling this plugin stops agents
  # reading and writing memories, it does not delete them, and they still have
  # to go when their owner does.
  module DataCleanup
    def self.install!
      Syrus::Installer.define("agent_memory:data_cleanup") do |scope|
        scope.effect("user memories") do
          Syrus::DataCleanup.register("User", "agent_memory.entries") do |user|
            AgentMemory::Entry.for_user(user).find_each(&:destroy)
          end
        end
      end
    end
  end
end
