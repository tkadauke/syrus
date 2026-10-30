class Coworkers::WorkspaceFileTools::Edit < Coworkers::WorkspaceFileTools::Base
  tool_name "edit_coworker_file"
  description "Replace exact text in an existing file inside the current coworker's persistent workspace."
  input_schema(properties: { path: { type: "string" }, old_text: { type: "string" }, new_text: { type: "string" }, replace_all: { type: "boolean" } }, required: %w[path old_text new_text])
  def self.call(path:, old_text:, new_text:, server_context:, replace_all: false) = safely { Mcp::Tools.success(path: workspace(server_context).edit(path, old_text, new_text, replace_all: replace_all)) }
end
