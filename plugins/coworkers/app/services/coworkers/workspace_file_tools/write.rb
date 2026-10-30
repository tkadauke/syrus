class Coworkers::WorkspaceFileTools::Write < Coworkers::WorkspaceFileTools::Base
  tool_name "write_coworker_file"
  description "Create or replace a file inside the current coworker's persistent workspace. Paths are relative; attached product repositories and Git metadata are inaccessible."
  input_schema(properties: { path: { type: "string" }, content: { type: "string" } }, required: %w[path content])
  def self.call(path:, content:, server_context:) = safely { Mcp::Tools.success(path: workspace(server_context).write(path, content)) }
end
