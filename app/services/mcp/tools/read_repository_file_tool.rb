require "mcp"

module Mcp::Tools
  class ReadRepositoryFileTool < MCP::Tool
    MAX_BYTES = 128.kilobytes
    tool_name "read_repository_file"
    description "Read a capped, secret-redacted repository file at a ref without requiring an attached checkout."
    input_schema(properties: {
      repository_id: { type: "integer" }, slug: { type: "string" }, ref: { type: "string" }, path: { type: "string" }
    }, required: %w[path])

    class << self
      def call(path:, server_context:, repository_id: nil, slug: nil, ref: nil)
        repository = CoworkerRepositoryAccess.resolve(server_context:, repository_id:, slug:)
        return repository if repository.is_a?(MCP::Tool::Response)

        content = RepositoryContent.for(repository, user: McpToolContext.from_server_context(server_context).user)
        revision = content.resolve(ref.presence || repository.default_branch)
        blob = content.read(revision, path.to_s)
        text = ToolPayloadRedactor.redact_text(blob.text.to_s)
        bounded = Mcp::Tools.truncate_text(text, MAX_BYTES)
        Mcp::Tools.success(repository: { id: repository.id, slug: repository.slug }, revision: revision.id,
          path: path, content: bounded[:text], total_bytes: text.bytesize, truncated: bounded[:truncated])
      rescue RepositoryContent::NotFound
        Mcp::Tools.invalid("file not found: #{path}")
      rescue RepositoryContent::Error => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
