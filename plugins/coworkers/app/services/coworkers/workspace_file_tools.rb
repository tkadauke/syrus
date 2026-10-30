module Coworkers::WorkspaceFileTools
  class Base < MCP::Tool
    class << self
      def workspace(server_context) = Coworkers::Workspace.new(server_context.fetch(:chat_session))

      def safely
        yield
      rescue Coworkers::Workspace::InvalidPath, SystemCallError => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end

  class Write < Base
    tool_name "write_coworker_file"
    description "Create or replace a file inside the current coworker's persistent workspace. Paths are relative; attached product repositories and Git metadata are inaccessible."
    input_schema(properties: { path: { type: "string" }, content: { type: "string" } }, required: %w[path content])
    def self.call(path:, content:, server_context:) = safely { Mcp::Tools.success(path: workspace(server_context).write(path, content)) }
  end

  class Edit < Base
    tool_name "edit_coworker_file"
    description "Replace exact text in an existing file inside the current coworker's persistent workspace."
    input_schema(properties: { path: { type: "string" }, old_text: { type: "string" }, new_text: { type: "string" }, replace_all: { type: "boolean" } }, required: %w[path old_text new_text])
    def self.call(path:, old_text:, new_text:, server_context:, replace_all: false) = safely { Mcp::Tools.success(path: workspace(server_context).edit(path, old_text, new_text, replace_all: replace_all)) }
  end

  class Move < Base
    tool_name "move_coworker_file"
    description "Move a file or directory within the current coworker's persistent workspace."
    input_schema(properties: { source: { type: "string" }, destination: { type: "string" } }, required: %w[source destination])
    def self.call(source:, destination:, server_context:) = safely { Mcp::Tools.success(workspace(server_context).move(source, destination)) }
  end

  class Delete < Base
    tool_name "delete_coworker_file"
    description "Delete a file or an empty directory inside the current coworker's persistent workspace."
    input_schema(properties: { path: { type: "string" } }, required: %w[path])
    def self.call(path:, server_context:) = safely { Mcp::Tools.success(path: workspace(server_context).delete(path)) }
  end
end
