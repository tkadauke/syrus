require "syrus_rails/schema_parser"
require "syrus_rails/migration_parser"
require "syrus_rails/route_parser"
require "syrus_rails/read_schema_tool"
require "syrus_rails/explain_migration_tool"
require "syrus_rails/list_routes_tool"
require "syrus_rails/mcp_tool_set"
require "syrus_rails/schema_erd_renderer"
require "syrus_rails/migration_diff_renderer"
require "syrus_rails/prompt_context"
require "syrus_rails/preview_provider"

module SyrusRails
  extend Syrus::PluginApi

  # Returns true when the given repo path looks like a Rails application.
  # Used by :preview_provider and other consumers before activating Rails-specific behavior.
  def self.detect?(repo_path)
    path = Pathname.new(repo_path)
    path.join("Gemfile").exist? &&
      path.join("config", "application.rb").exist? &&
      path.join("bin", "rails").exist?
  end

  # Direct (instance rather than class) registration of the preview provider,
  # kept because it is a different registration path from the manifest's.
  def self.register!
    Syrus::PluginRegistry.register(:preview_provider, PreviewProvider.new)
  end

  syrus_plugin "syrus-rails" do
    description "Ruby on Rails framework intelligence."
    long_description "Syrus Rails layers Rails-specific behavior on top of the generic Ruby plugin. It understands Rails migrations, eager loading, schema checks, preview boot, routes, models, and framework-specific review criteria so agents can work with Rails apps safely.\n\nUse it for Rails repositories where plain Ruby support is not enough. It depends on the Ruby plugin and contributes the Rails-specific graders, MCP helpers, artifact renderers, and preview integration used by Syrus itself."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/syrus-rails.svg"
    author "Thomas Kadauke"
    category "language"
    depends_on [ "ruby" ]

    provides mcp_tool_set: "SyrusRails::McpToolSet",
             artifact_renderer: [ "SyrusRails::SchemaErdRenderer", "SyrusRails::MigrationDiffRenderer" ],
             prompt_injector: "SyrusRails::PromptContext",
             preview_provider: "SyrusRails::PreviewProvider"
  end
end
