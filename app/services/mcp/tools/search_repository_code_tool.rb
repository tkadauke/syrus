require "mcp"

module Mcp::Tools
  class SearchRepositoryCodeTool < MCP::Tool
    MAX_FILES = 300
    MAX_RESULTS = 100
    MAX_FILE_BYTES = 256.kilobytes
    tool_name "search_repository_code"
    description "Search capped repository text at a ref without requiring an attached checkout."
    input_schema(properties: {
      repository_id: { type: "integer" }, slug: { type: "string" }, ref: { type: "string" },
      query: { type: "string" }, path: { type: "string" }
    }, required: %w[query])

    class << self
      def call(query:, server_context:, repository_id: nil, slug: nil, ref: nil, path: nil)
        return Mcp::Tools.invalid("query must not be blank") if query.to_s.blank?
        repository = CoworkerRepositoryAccess.resolve(server_context:, repository_id:, slug:)
        return repository if repository.is_a?(MCP::Tool::Response)

        context = McpToolContext.from_server_context(server_context)
        content = RepositoryContent.for(repository, user: context.user)
        revision = content.resolve(ref.presence || repository.default_branch)
        prefix = path.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
        candidates = content.tree(revision).select do |entry|
          entry.file? && (prefix.blank? || entry.path == prefix || entry.path.start_with?("#{prefix}/"))
        end.first(MAX_FILES)
        results = candidates.filter_map { |entry| matches(content, revision, entry.path, query.to_s) }.flatten.first(MAX_RESULTS)
        Mcp::Tools.success(repository: { id: repository.id, slug: repository.slug }, revision: revision.id,
          query: query, results: ToolPayloadRedactor.redact(results), truncated: candidates.length == MAX_FILES || results.length == MAX_RESULTS)
      rescue RepositoryContent::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def matches(content, revision, path, query)
        blob = content.read(revision, path)
        return if blob.text.to_s.bytesize > MAX_FILE_BYTES

        blob.text.to_s.lines.each_with_index.filter_map do |line, index|
          if line.include?(query)
            redacted = ToolPayloadRedactor.redact_text(line.strip)
            { path: path, line: index + 1, text: Mcp::Tools.safe_byteslice(redacted, 0, 1.kilobyte) }
          end
        end
      rescue RepositoryContent::NotFound, Encoding::CompatibilityError
        nil
      end
    end
  end
end
