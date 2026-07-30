module Syrus
  module Plugin
    # Interface for plugins that provide preview server configuration.
    # Include this module in a provider class and implement all five methods.
    # Register an instance with: Syrus::PluginRegistry.register(:preview_provider, MyProvider.new)
    module PreviewProvider
      # Returns true if the plugin applies to the given repository path.
      def detect?(repo_path)
        raise NotImplementedError, "#{self.class}#detect? must be implemented"
      end

      # Shell command to start the preview server, bound to the given port.
      def start_command(port:)
        raise NotImplementedError, "#{self.class}#start_command must be implemented"
      end

      # Shell command to seed the database before starting the preview server.
      # Return nil if no seeding is needed.
      def seed_command
        raise NotImplementedError, "#{self.class}#seed_command must be implemented"
      end

      # URL path the preview host polls to determine the app is ready.
      def health_check_path
        raise NotImplementedError, "#{self.class}#health_check_path must be implemented"
      end

      # Array of log file paths (relative to the repo root) to tail for output.
      def log_paths
        raise NotImplementedError, "#{self.class}#log_paths must be implemented"
      end
    end
  end
end
