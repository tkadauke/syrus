require "rails/generators"
require "rails/generators/named_base"

module Syrus
  module Plugin
    # Usage: rails generate syrus:plugin NAME
    #
    # Scaffolds a minimal Syrus::PluginApi plugin under plugins/NAME/.
    class PluginGenerator < Rails::Generators::NamedBase
      source_root Rails.root.join("cli/cmd/plugin_scaffold/templates")
      class_option :frontend, type: :boolean, default: false, desc: "Generate a semantic UI admin-page example"
      class_option :model, type: :boolean, default: false, desc: "Generate a plugin-owned model and migration"
      class_option :cli, type: :boolean, default: false, desc: "Generate a server-backed CLI command"
      class_option :syrus_version, type: :string, default: "0.1.0", desc: "Oldest supported Syrus release"

      def create_plugin_directory
        empty_directory plugin_dir
      end

      def create_gemspec
        scaffold "plugin.gemspec", "#{plugin_dir}/#{file_name}.gemspec"
      end

      def create_entrypoint
        scaffold "lib/plugin.rb", "#{plugin_dir}/lib/#{file_name}.rb"
        scaffold "app/services/plugin/callbacks.rb", "#{plugin_dir}/app/services/#{file_name}/callbacks.rb"
        scaffold "locales/en.json", "#{plugin_dir}/app/frontend/i18n/locales/en/#{file_name}.json"
        scaffold "locales/de.json", "#{plugin_dir}/app/frontend/i18n/locales/de/#{file_name}.json"
        scaffold "locales/la.json", "#{plugin_dir}/app/frontend/i18n/locales/la/#{file_name}.json"
        scaffold "dist/plugin.js", "#{plugin_dir}/dist/frontend/plugin.js"
        scaffold "dist/manifest.json", "#{plugin_dir}/dist/frontend/manifest.json"
        scaffold "spec/plugin_spec.rb", "#{plugin_dir}/spec/#{file_name}_spec.rb"
        scaffold "README.md", "#{plugin_dir}/README.md"
        scaffold "gitignore", "#{plugin_dir}/.gitignore"
        scaffold "github/workflows/test.yml", "#{plugin_dir}/.github/workflows/test.yml"
      end

      def create_frontend_example
        return unless frontend?

        scaffold "app/services/plugin/admin_pages.rb", "#{plugin_dir}/app/services/#{file_name}/admin_pages.rb"
        scaffold "frontend/entry.tsx", "#{plugin_dir}/frontend/entry.tsx"
        scaffold "frontend/style.css", "#{plugin_dir}/frontend/style.css"
        scaffold "dist/plugin_frontend.js", "#{plugin_dir}/dist/frontend/plugin.js"
        scaffold "dist/plugin.css", "#{plugin_dir}/dist/frontend/plugin.css"
        scaffold "dist/manifest_frontend.json", "#{plugin_dir}/dist/frontend/manifest.json"
      end

      def create_model_example
        return unless options[:model]

        scaffold "app/models/plugin/widget.rb", "#{plugin_dir}/app/models/#{file_name}/widget.rb"
        scaffold "db/migrate/create_widgets.rb", "#{plugin_dir}/db/migrate/20200101000000_create_#{file_name}_widgets.rb"
      end

      def create_cli_example
        return unless options[:cli]

        scaffold "app/services/plugin/cli/hello.rb", "#{plugin_dir}/app/services/#{file_name}/cli/hello.rb"
      end

      private

      def plugin_dir
        Syrus::PluginRoots.new(application_root: destination_root_path).built_in_root.join(file_name).relative_path_from(destination_root_path).to_s
      end

      def destination_root_path
        Pathname.new(destination_root).expand_path
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

      def scaffold(source, destination)
        content = File.read(File.join(self.class.source_root, source))
        create_file destination, render_scaffold(content), force: true
      end

      def render_scaffold(content)
        replacements = {
          "PLUGIN_NAME" => file_name,
          "MODULE_NAME" => module_name,
          "DISPLAY_NAME" => display_name,
          "SYRUS_VERSION" => options[:syrus_version],
          "FRONTEND_DECLARATION" => frontend? ? 'bundle: "dist/frontend/plugin.js", css: "dist/frontend/plugin.css", i18n: [ "app/frontend/i18n/locales/*/' + file_name + '.json" ]' : 'bundle: "dist/frontend/plugin.js", i18n: [ "app/frontend/i18n/locales/*/' + file_name + '.json" ]',
          "OPTIONAL_PROVIDERS" => frontend? ? "    provides admin_page: \"#{module_name}::AdminPages\"\n" : "",
          "OPTIONAL_CLI" => options[:cli] ? "    cli_commands [ { path: %w[#{file_name} hello], summary: \"Say hello\", handler: \"#{module_name}::Cli::Hello\" } ]\n" : ""
        }
        replacements.reduce(content) { |result, (key, value)| result.gsub("{{#{key}}}", value.to_s) }
      end
    end
  end
end
