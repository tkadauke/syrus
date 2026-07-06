module Coverage
  class LcovParser
    def initialize(content, workspace: nil)
      @content = content.to_s
      @workspace = workspace&.to_s&.then { |w| w.end_with?("/") ? w : "#{w}/" }
    end

    def parse
      files = {}
      current = nil

      @content.each_line do |raw_line|
        line = raw_line.strip
        case line
        when /\ASF:(.+)/
          path = strip_workspace($1.strip)
          current = { path: path, lines: {}, brh: nil, brf: nil, fnh: nil, fnf: nil }
        when /\ADA:(\d+),(\d+)/
          current[:lines][$1.to_i] = $2.to_i if current
        when /\ABRH:(\d+)/
          current[:brh] = $1.to_i if current
        when /\ABRF:(\d+)/
          current[:brf] = $1.to_i if current
        when /\AFNH:(\d+)/
          current[:fnh] = $1.to_i if current
        when /\AFNF:(\d+)/
          current[:fnf] = $1.to_i if current
        when "end_of_record"
          if current
            files[current[:path]] = {
              lines: current[:lines],
              branches: current[:brh].nil? ? nil : { hit: current[:brh], found: current[:brf] || 0 },
              functions: current[:fnh].nil? ? nil : { hit: current[:fnh], found: current[:fnf] || 0 }
            }
            current = nil
          end
        end
      end

      { files: files }
    end

    private

    def strip_workspace(path)
      return path unless @workspace
      path.start_with?(@workspace) ? path[@workspace.length..] : path
    end
  end
end

Coverage::ParserRegistry.register("lcov", Coverage::LcovParser)
