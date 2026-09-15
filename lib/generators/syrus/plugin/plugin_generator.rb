require "rails/generators"
require "rails/generators/named_base"

module Syrus
  module Plugin
    # Usage: rails generate syrus:plugin NAME
    #
    # Scaffolds a minimal Syrus::PluginApi plugin under plugins/NAME/.
    class PluginGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)
      class_option :frontend, type: :boolean, default: false, desc: "Generate a semantic UI admin-page example"

      def create_plugin_directory
        empty_directory plugin_dir
      end

      def create_gemspec
        template "plugin.gemspec.tt", "#{plugin_dir}/#{file_name}.gemspec"
      end

      def create_entrypoint
        template "lib/plugin.rb.tt", "#{plugin_dir}/lib/#{file_name}.rb"
      end

      def create_frontend_example
        return unless frontend?

        template "app/services/plugin/admin_pages.rb.tt", "#{plugin_dir}/app/services/#{file_name}/admin_pages.rb"
        template "app/frontend/routes/AdminExample.tsx.tt", "#{plugin_dir}/app/frontend/routes/AdminExample.tsx"
        template "app/frontend/i18n/locales/en/plugin.json.tt", "#{plugin_dir}/app/frontend/i18n/locales/en/#{file_name}.json"
        template "app/frontend/i18n/locales/de/plugin.json.tt", "#{plugin_dir}/app/frontend/i18n/locales/de/#{file_name}.json"
        template "app/frontend/i18n/locales/la/plugin.json.tt", "#{plugin_dir}/app/frontend/i18n/locales/la/#{file_name}.json"
      end

      private

      def plugin_dir
        "plugins/#{file_name}"
      end

      def module_name
        file_name.camelize
      end

      def display_name
        file_name.humanize
      end

      def frontend?
        options[:frontend]
      end
    end
  end
end
