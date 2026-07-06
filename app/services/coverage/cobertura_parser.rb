module Coverage
  class CoberturaParser
    def initialize(content, workspace: nil)
      @content = content.to_s
      @workspace = workspace&.to_s&.then { |w| w.end_with?("/") ? w : "#{w}/" }
    end

    def parse
      return { files: {} } if @content.blank?

      doc = Nokogiri::XML(@content) { |cfg| cfg.strict }
      files = {}

      doc.xpath("//class").each do |klass|
        filename = klass["filename"].to_s.strip
        next if filename.empty?

        path = strip_workspace(filename)
        lines = {}

        klass.xpath("lines/line").each do |line_node|
          number = line_node["number"]&.to_i
          hits = line_node["hits"]&.to_i
          lines[number] = hits if number && hits
        end

        files[path] = { lines: lines, branches: nil, functions: nil }
      end

      { files: files }
    rescue Nokogiri::XML::SyntaxError
      { files: {} }
    end

    private

    def strip_workspace(path)
      return path unless @workspace
      path.start_with?(@workspace) ? path[@workspace.length..] : path
    end
  end
end

Coverage::ParserRegistry.register("cobertura", Coverage::CoberturaParser)
