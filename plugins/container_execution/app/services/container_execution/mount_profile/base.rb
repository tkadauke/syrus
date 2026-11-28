module ContainerExecution
  module MountProfile
    class Base
      PROFILES = {
        "standard" => -> { Standard },
        "executable_scratch" => -> { ExecutableScratch }
      }.freeze

      def self.for(name)
        resolver = PROFILES[name.to_s]
        resolver&.call&.new
      end

      def tmpfs_args
        [ "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=#{Configuration.chat_agent_tmpfs_size}" ]
      end
    end
  end
end
