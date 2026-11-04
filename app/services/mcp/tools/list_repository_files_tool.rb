require "mcp"

module Mcp::Tools
  class ListRepositoryFilesTool < MCP::Tool
    tool_name "list_repository_files"
    description "List paths from a repository at a ref. Capped or provider-truncated listings explicitly report incomplete status, coverage, and guidance to narrow path or retry."
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
        listed = entries.first(cap)
        incomplete = entries.length > cap
        Mcp::Tools.success(repository: { id: repository.id, slug: repository.slug }, revision: revision.id,
          path: prefix.presence, entries: serialize(listed), status: incomplete ? "incomplete" : "complete",
          incomplete:, reason: incomplete ? "result_limit" : nil, searched_paths: listed.map(&:path),
          coverage: { candidate_entries: entries.length, returned_entries: listed.length,
                      percent: entries.empty? ? 100.0 : ((listed.length.fdiv(entries.length) * 100).round(1)) },
          truncated: incomplete, hint: incomplete ? "Listing is incomplete. Narrow path or retry." : nil)
      rescue RepositoryContent::Truncated => e
        listed = e.partial.first(500)
        Mcp::Tools.success(repository: { id: repository.id, slug: repository.slug }, entries: serialize(listed),
          status: "inconclusive", incomplete: true, reason: "provider_limit", searched_paths: listed.map(&:path),
          coverage: { returned_entries: listed.length, total_entries: nil, percent: nil }, truncated: true,
          hint: "Listing is incomplete because the repository provider truncated it. Narrow path or retry.")
      rescue RepositoryContent::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def serialize(entries)
        entries.map { |entry| { path: entry.path, type: entry.type, size: entry.size } }
      end
    end
  end
end
