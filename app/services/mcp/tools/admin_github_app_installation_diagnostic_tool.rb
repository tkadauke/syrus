require "mcp"

module Mcp::Tools
  class AdminGithubAppInstallationDiagnosticTool < MCP::Tool
    tool_name "admin_github_app_installation_diagnostic"

    description <<~DESC
      Diagnose GitHub App registration, installation sync, repository linkage,
      and PAT fallback reasons for one repository slug or all active repositories.
    DESC

    input_schema(
      properties: {
        repository: {
          type: "string",
          description: "Optional repository slug, such as owner/name. Omit to diagnose all active repositories."
        }
      }
    )

    class << self
      def call(server_context:, repository: nil)
        return Mcp::Tools.unauthorized("Admin access required") unless server_context.fetch(:chat_session).user.admin?

        Mcp::Tools.success(GithubAppInstallationDiagnostic.new(slug: repository).show)
      end
    end
  end
end
