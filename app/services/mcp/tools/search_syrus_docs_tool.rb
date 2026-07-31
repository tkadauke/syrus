require "mcp"

module Mcp::Tools
  class SearchSyrusDocsTool < MCP::Tool
    tool_name "search_syrus_docs"

    description "Search the Syrus feature documentation corpus. Returns the most relevant sections for questions about workflow steps, AppSettings, feature flags, .syrus.yml options, graders, the landing queue, and other Syrus-specific behaviors."

    input_schema(
      properties: {
        query: { type: "string", description: "Keywords to search for in the Syrus documentation." }
      },
      required: %w[query]
    )

    MAX_RESULTS = 3
    MAX_SECTION_CHARS = 600

    class << self
      def call(query:, server_context:)
        query = query.to_s.strip
        return Mcp::Tools.invalid("query is required") if query.empty?

        words = query.downcase.split(/\W+/).reject(&:empty?)
        sections = load_sections

        scored = sections.filter_map do |section|
          haystack = "#{section[:doc_title]} #{section[:heading]} #{section[:body]}".downcase
          score = words.count { |word| haystack.include?(word) }
          section.merge(score: score) if score > 0
        end

        top = scored.sort_by { |s| -s[:score] }.first(MAX_RESULTS)

        if top.empty?
          return MCP::Tool::Response.new([ { type: "text", text: "No matching documentation found for '#{query}'. Try broader terms." } ])
        end

        text = top.map { |s| format_section(s) }.join("\n\n---\n\n")
        MCP::Tool::Response.new([ { type: "text", text: text } ])
      end

      def docs_dir
        Rails.root.join("config/syrus_docs")
      end

      private

      def load_sections
        dir = docs_dir
        return [] unless Dir.exist?(dir)

        Dir.glob(dir.join("*.md")).flat_map { |path| parse_sections(path) }
      end

      def parse_sections(path)
        content = File.read(path, encoding: "utf-8")
        filename = File.basename(path, ".md")
        doc_title = content.match(/\A#\s+(.+)/)&.captures&.first&.strip || filename

        parts = content.split(/^(?=## )/)
        sections = []

        parts.each do |part|
          if part.start_with?("## ")
            lines = part.lines
            heading = lines.first.sub(/\A##\s+/, "").strip
            body = lines[1..].join.strip
            sections << { doc_title: doc_title, heading: heading, body: body }
          else
            body = part.sub(/\A#\s+.+\n/, "").strip
            sections << { doc_title: doc_title, heading: doc_title, body: body } unless body.empty?
          end
        end

        sections
      end

      def format_section(section)
        body = section[:body].to_s
        body = "#{body[0, MAX_SECTION_CHARS]}…" if body.length > MAX_SECTION_CHARS
        "## #{section[:doc_title]} > #{section[:heading]}\n#{body}"
      end
    end
  end
end
