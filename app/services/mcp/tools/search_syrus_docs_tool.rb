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
    NAMED_PLUGIN_BOOST = 3

    class << self
      def call(query:, server_context:)
        query = query.to_s.strip
        return Mcp::Tools.invalid("query is required") if query.empty?

        words = query.downcase.split(/\W+/).reject(&:empty?)
        sections = load_sections

        scored = sections.filter_map do |section|
          haystack = "#{section[:doc_title]} #{section[:heading]} #{section[:body]}".downcase
          score = words.count { |word| haystack.include?(word) }
          # A disabled plugin contributes one teaser against a corpus of dozens
          # of core files, so naming the plugin outright has to be enough to
          # surface it -- otherwise the agent is told the capability does not
          # exist when it is one toggle away.
          score += NAMED_PLUGIN_BOOST if section[:plugin_name].present? && words.include?(section[:plugin_name])
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

      # Where a plugin keeps its own full documentation, so deleting the plugin
      # directory removes its docs with it.
      def plugin_docs_dir(name)
        Rails.root.join("plugins", name.to_s, "docs/syrus_docs")
      end

      private

      # Core's docs, plus the full docs of every enabled plugin, plus a single
      # teaser for each plugin that is installed but switched off -- so an agent
      # searching for a capability learns it exists and is one toggle away,
      # instead of finding nothing.
      def load_sections
        core_sections + plugin_sections
      end

      def core_sections
        return [] unless Dir.exist?(docs_dir)

        Dir.glob(docs_dir.join("*.md")).flat_map { |path| parse_sections(path) }
      end

      def plugin_sections
        Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
          manifest.enabled? ? enabled_plugin_sections(manifest) : disabled_plugin_teaser(manifest)
        rescue StandardError => e
          Rails.logger.warn("[search_syrus_docs] skipped #{manifest.name}: #{e.class}: #{e.message}")
          []
        end
      end

      def enabled_plugin_sections(manifest)
        dir = plugin_docs_dir(manifest.name)
        return [] unless Dir.exist?(dir)

        Dir.glob(dir.join("**/*.md")).flat_map { |path| parse_sections(path) }
      end

      # Deliberately not a separate teaser file: every manifest already carries
      # a description written as "what this would give you", it is what the
      # admin Plugins page renders, and a second copy would drift from it.
      #
      # A plugin that cannot be disabled never reaches this branch.
      def disabled_plugin_teaser(manifest)
        blurb = manifest.long_description.presence || manifest.description.presence
        return [] if blurb.blank?

        title = "#{manifest.display_name.presence || manifest.name} (plugin disabled)"
        [ {
          doc_title: title,
          plugin_name: manifest.name.to_s.downcase,
          heading: "What enabling this would add",
          # The notice leads: a long description would otherwise push it past
          # MAX_SECTION_CHARS and the agent would read the blurb as a
          # description of something it can use right now.
          body: "This plugin is installed but currently DISABLED, so none of what follows is " \
                "available until an operator enables it from Admin -> Plugins " \
                "(plugin name: #{manifest.name}).\n\n#{blurb}"
        } ]
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
