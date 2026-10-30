class Coworkers::WorkspaceFileTools::Move < Coworkers::WorkspaceFileTools::Base
  tool_name "move_coworker_file"
  description "Move a file or directory within the current coworker's persistent workspace."
  input_schema(properties: { source: { type: "string" }, destination: { type: "string" } }, required: %w[source destination])
  def self.call(source:, destination:, server_context:) = safely { Mcp::Tools.success(workspace(server_context).move(source, destination)) }
end
