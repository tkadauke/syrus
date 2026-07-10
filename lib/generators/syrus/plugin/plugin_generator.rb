require "rails/generators"
require "rails/generators/named_base"

module Syrus
  module Plugin
    # Usage: rails generate syrus:plugin NAME
    #
    # Scaffolds a minimal Rails Engine skeleton under plugins/NAME/ that can
    # self-register with Syrus::PluginRegistry on boot.
    class PluginGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      def create_plugin_directory
        empty_directory plugin_dir
      end

      def create_gemspec
        template "plugin.gemspec.tt", "#{plugin_dir}/#{file_name}.gemspec"
      end

      def create_version
        template "lib/plugin/version.rb.tt", "#{plugin_dir}/lib/#{file_name}/version.rb"
      end

      def create_engine
        template "lib/plugin/engine.rb.tt", "#{plugin_dir}/lib/#{file_name}/engine.rb"
      end

      def create_entrypoint
        template "lib/plugin.rb.tt", "#{plugin_dir}/lib/#{file_name}.rb"
      end

      private

      def plugin_dir
        "plugins/#{file_name}"
      end

      def module_name
        file_name.camelize
      end
    end
  end
end
