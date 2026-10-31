require "mcp"

module Mcp::Tools
  class ListRepositoryFilesTool < MCP::Tool
    tool_name "list_repository_files"
    description "List capped paths from a repository at a ref without requiring an attached checkout."
    input_schema(properties: {
      repository_id: { type: "integer" }, slug: { type: "string" }, ref: { type: "string" },
      path: { type: "string" }, limit: { type: "integer", description: "Maximum paths, capped at 500." }
    })

    class << self
      def call(server_context:, repository_id: nil, slug: nil, ref: nil, path: nil, limit: 200)
        repository = CoworkerRepositoryAccess.resolve(server_context:, repository_id:, slug:)
        return repository if repository.is_a?(MCP::Tool::Response)

        content = RepositoryContent.for(repository, user: McpToolContext.from_server_context(server_context).user)
        revision = content.resolve(ref.presence || repository.default_branch)
        prefix = path.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
        entries = content.tree(revision)
        entries = entries.select { |entry| prefix.blank? || entry.path == prefix || entry.path.start_with?("#{prefix}/") }
        cap = limit.to_i.clamp(1, 500)
        Mcp::Tools.success(repository: { id: repository.id, slug: repository.slug }, revision: revision.id,
          path: prefix.presence, entries: entries.first(cap).map { |entry| { path: entry.path, type: entry.type, size: entry.size } },
          truncated: entries.length > cap)
      rescue RepositoryContent::Truncated => e
        Mcp::Tools.success(repository: { id: repository.id, slug: repository.slug }, entries: e.partial.first(500).map { |entry| { path: entry.path, type: entry.type, size: entry.size } }, truncated: true)
      rescue RepositoryContent::Error => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
