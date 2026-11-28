module ContainerExecution
  module MountProfile
    class ExecutableScratch < Base
      def tmpfs_args
        super + [ "--tmpfs", "/scratch:rw,nosuid,nodev,exec,size=#{Configuration.chat_agent_scratch_size}" ]
      end
    end
  end
end
