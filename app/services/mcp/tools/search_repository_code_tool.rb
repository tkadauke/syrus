require "mcp"
require "timeout"

module Mcp::Tools
  class SearchRepositoryCodeTool < MCP::Tool
    MAX_FILES = 300
    MAX_RESULTS = 100
    MAX_FILE_BYTES = 256.kilobytes
    TIME_BUDGET = 20.seconds
    EXCLUDED_PATH_SEGMENTS = %w[node_modules vendor tmp log coverage dist build .git].to_set.freeze
    tool_name "search_repository_code"
    description "Search repository text at a ref. Results explicitly report complete, no_match, or inconclusive with coverage and retry guidance when a time, file, or result budget is reached. Narrow path for large repositories."
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
        prefix = path.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
        revision = nil
        candidates = nil
        progress = { results: [], searched_paths: [], skipped_large_files: 0, reason: nil }

        Timeout.timeout(TIME_BUDGET) do
          revision = content.resolve(ref.presence || repository.default_branch)
          candidates = content.tree(revision).select do |entry|
            entry.file? && (prefix.blank? || entry.path == prefix || entry.path.start_with?("#{prefix}/"))
          end.reject { |entry| prefix.blank? && excluded_path?(entry.path) }
          scan(content, revision, candidates, query.to_s, progress)
        end
        payload(repository:, revision:, query:, prefix:, candidates:, **progress)
      rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
        progress[:reason] = "time_budget"
        payload(repository:, revision:, query:, prefix:, candidates:, **progress)
      rescue RepositoryContent::Unavailable => e
        return Mcp::Tools.invalid(e.message) unless e.message.match?(/timeout/i)

        progress[:reason] = "time_budget"
        payload(repository:, revision:, query:, prefix:, candidates:, **progress)
      rescue RepositoryContent::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def scan(content, revision, candidates, query, progress)
        progress[:reason] = "file_limit" if candidates.length > MAX_FILES

        candidates.first(MAX_FILES).each do |entry|
          blob = content.read(revision, entry.path, max_bytes: MAX_FILE_BYTES + 1)
          progress[:searched_paths] << entry.path
          if blob.text.to_s.bytesize > MAX_FILE_BYTES
            progress[:skipped_large_files] += 1
            next
          end
          progress[:results].concat(matches(blob.text.to_s, entry.path, query))
          if progress[:results].length >= MAX_RESULTS
            progress[:results] = progress[:results].first(MAX_RESULTS)
            progress[:reason] = "result_limit"
            break
          end
        rescue RepositoryContent::NotFound, Encoding::CompatibilityError
          progress[:searched_paths] << entry.path unless progress[:searched_paths].last == entry.path
        end
      end

      def matches(text, path, query)
        text.lines.each_with_index.filter_map do |line, index|
          next unless line.include?(query)

          redacted = ToolPayloadRedactor.redact_text(line.strip)
          { path: path, line: index + 1, text: Mcp::Tools.safe_byteslice(redacted, 0, 1.kilobyte) }
        end
      end

      def payload(repository:, revision:, query:, prefix:, candidates:, results:, searched_paths:, skipped_large_files:, reason:)
        incomplete = reason.present?
        status = incomplete && results.empty? ? "inconclusive" : (results.empty? ? "no_match" : (incomplete ? "incomplete" : "complete"))
        coverage = {
          candidate_files: candidates&.length,
          searched_files: searched_paths.length,
          skipped_large_files: skipped_large_files,
          percent: coverage_percent(candidates, searched_paths)
        }
        Mcp::Tools.success(repository: { id: repository.id, slug: repository.slug }, revision: revision&.id,
          query:, path: prefix.presence, status:, results: ToolPayloadRedactor.redact(results), incomplete:,
          reason:, searched_paths:, coverage:, truncated: incomplete,
          hint: incomplete ? "Search is incomplete; no match means no match in the searched portion only. Narrow path or retry." : nil)
      end

      def coverage_percent(candidates, searched_paths)
        return if candidates.nil?
        return 100.0 if candidates.empty?

        (searched_paths.length.fdiv(candidates.length) * 100).round(1)
      end

      def excluded_path?(path)
        path.split("/").any? { |segment| EXCLUDED_PATH_SEGMENTS.include?(segment) }
      end
    end
  end
end
