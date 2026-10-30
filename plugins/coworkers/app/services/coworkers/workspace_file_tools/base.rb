class Coworkers::WorkspaceFileTools::Base < MCP::Tool
  class << self
    def workspace(server_context) = Coworkers::Workspace.new(server_context.fetch(:chat_session))

    def safely
      yield
    rescue Coworkers::Workspace::InvalidPath, SystemCallError => e
      Mcp::Tools.invalid(e.message)
    end
  end
end
