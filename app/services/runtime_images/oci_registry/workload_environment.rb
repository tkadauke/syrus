module RuntimeImages
  module OciRegistry
    # Keeps deployment registry configuration and credentials out of workload
    # processes. Workers receive only scoped, short-lived pull grants.
    module WorkloadEnvironment
      module_function

      # Returns env without deployment registry variables. When the child
      # would inherit this process's environment, variables that are set here
      # are explicitly unset (nil) so inheritance cannot leak them.
      def scrub(env, inherit: false, source: ENV)
        names = Configuration.env_names
        scrubbed = env.reject { |key, _| names.include?(key.to_s) }
        return scrubbed unless inherit
        names.each { |name| scrubbed[name] = nil if source.key?(name) }
        scrubbed
      end
    end
  end
end
