class Coworkers::WorkspaceFileTools::Delete < Coworkers::WorkspaceFileTools::Base
  tool_name "delete_coworker_file"
  description "Delete a file or an empty directory inside the current coworker's persistent workspace."
  input_schema(properties: { path: { type: "string" } }, required: %w[path])
  def self.call(path:, server_context:) = safely { Mcp::Tools.success(path: workspace(server_context).delete(path)) }
end
