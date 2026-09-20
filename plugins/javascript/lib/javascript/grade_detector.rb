require "json"
require "pathname"

module JavaScript
  class GradeDetector
    include Syrus::Plugin::GradeDetector

    def self.grade_candidates(repo_path)
      new(repo_path).grade_candidates
    end

    def initialize(repo_path)
      @path = Pathname.new(repo_path)
    end

    def grade_candidates
      return [] unless vitest_evidence

      [
        {
          name: "vitest",
          run: "type: vitest",
          type: "vitest",
          evidence: vitest_evidence
        }
      ]
    end

    private

    def vitest_evidence
      return @vitest_evidence if defined?(@vitest_evidence)

      @vitest_evidence =
        vitest_config ||
        package_json_vitest_evidence
    end

    def vitest_config
      Dir.glob(@path.join("vitest.config.*").to_s).map { |path| File.basename(path) }.sort.first
    end

    def package_json_vitest_evidence
      package_json = @path.join("package.json")
      return nil unless package_json.file?

      payload = JSON.parse(package_json.read)
      scripts = payload.fetch("scripts", {})
      deps = payload.fetch("dependencies", {}).merge(payload.fetch("devDependencies", {}))
      return "package.json scripts" if scripts.values.any? { |command| command.to_s.match?(/\bvitest\b/) }
      return "package.json dependencies" if deps.key?("vitest")

      nil
    rescue JSON::ParserError
      nil
    end
  end
end
