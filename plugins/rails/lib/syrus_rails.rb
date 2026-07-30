require "syrus_rails/version"
require "syrus_rails/mcp_tool_set"
require "syrus_rails/schema_erd_renderer"
require "syrus_rails/migration_diff_renderer"
require "syrus_rails/rspec_parser"
require "syrus_rails/simple_cov_analyzer"
require "syrus_rails/prompt_context"
require "syrus_rails/preview_provider"
require "syrus_rails/engine"

module SyrusRails
  # Returns true when the given repo path looks like a Rails application.
  # Used by :preview_provider and other consumers before activating Rails-specific behavior.
  def self.detect?(repo_path)
    path = Pathname.new(repo_path)
    path.join("Gemfile").exist? &&
      path.join("config", "application.rb").exist? &&
      path.join("bin", "rails").exist?
  end
end
