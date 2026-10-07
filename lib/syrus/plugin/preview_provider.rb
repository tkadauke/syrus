module Syrus
  module Plugin
    # Interface for `:preview_provider` extension points. Plugin gems implement
    # this interface to tell Syrus how to start, seed, and health-check a preview
    # app for a given repository.
    #
    # Usage:
    #   class MyPlugin::PreviewProvider
    #     include Syrus::Plugin::PreviewProvider
    #
    #     def detect?(repo_path) = File.exist?(File.join(repo_path, "Gemfile"))
    #     def start_command(port:) = "bin/rails server -p #{port}"
    #     def setup_commands = ["bundle install"]
    #     def seed_command = "bin/rails db:seed"
    #     def health_check_path = "/"
    #     def health_check_timeout_seconds = 120
    #     def log_paths = ["log/development.log"]
    #     def env = { "RAILS_ENV" => "development" }
    #     def unset_env = ["DATABASE_URL"]
    #   end
    #
    #   Syrus::PluginRegistry.register(
    #     name: "my-preview-plugin", version: "1.0.0",
    #     provides: { preview_provider: MyPlugin::PreviewProvider }
    #   )
    module PreviewProvider
      def self.register(provider)
        registry << provider
      end

      def self.registry
        @registry ||= []
      end

      def self.for_repo(repo_path)
        performance_phase("plugin.preview_provider.for_repo") do
          provider_candidates.find do |p|
            performance_plugin_call(extension_point: :preview_provider, provider: p, operation: :detect) do
              p.detect?(repo_path)
            end
          end
        end
      end

      def self.configured?
        performance_phase("plugin.preview_provider.configured") do
          registry.any? || Syrus::PluginRegistry.providers_for(:preview_provider).any?
        end
      end

      def self.provider_candidates
        performance_phase("plugin.preview_provider.provider_candidates") do
          registry + Syrus::PluginRegistry.providers_for(:preview_provider).filter_map do |provider|
            performance_plugin_call(extension_point: :preview_provider, provider: provider, operation: :instantiate) do
              instantiate(provider)
            end
          end
        end
      end

      def self.instantiate(provider)
        return provider if provider.respond_to?(:detect?)
        return provider.new if provider.respond_to?(:new)

        nil
      end

      def self.performance_phase(name, metadata = {}, &block)
        if defined?(PerformanceLogging)
          PerformanceLogging.phase(name, metadata, &block)
        else
          yield
        end
      end

      def self.performance_plugin_call(extension_point:, provider:, operation:, &block)
        if defined?(PerformanceLogging)
          PerformanceLogging.plugin_call(extension_point: extension_point, provider: provider, operation: operation, &block)
        else
          yield
        end
      end

      # -- Interface methods providers must implement --

      def detect?(_repo_path)
        raise NotImplementedError, "#{self.class}#detect? is required"
      end

      def start_command(port:)
        raise NotImplementedError, "#{self.class}#start_command is required"
      end

      def seed_command
        nil
      end

      def setup_commands
        []
      end

      def health_check_path
        "/"
      end

      def health_check_timeout_seconds
        nil
      end

      def log_paths
        []
      end

      def env
        {}
      end

      def unset_env
        []
      end
    end
  end
end
