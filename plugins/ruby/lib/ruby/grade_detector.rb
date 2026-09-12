require "pathname"

module Ruby
  class GradeDetector
    include Syrus::Plugin::GradeDetector

    def self.grade_candidates(repo_path)
      new(repo_path).grade_candidates
    end

    def initialize(repo_path)
      @path = Pathname.new(repo_path)
    end

    def grade_candidates
      return [] unless rspec?

      [
        {
          name: "rspec",
          run: "bundle exec rspec",
          phases: %w[landing ci],
          junit_output: ".syrus/grade-output/rspec-junit.xml",
          failures: "allow_inherited",
          base_retry: { "strategy" => "plugin" },
          evidence: rspec_evidence
        },
        {
          name: "rspec-focused",
          run: "bundle exec rspec",
          phases: %w[review],
          when_files_changed: [ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb" ],
          junit_output: ".syrus/grade-output/rspec-focused-junit.xml",
          failures: "allow_inherited",
          base_retry: { "strategy" => "plugin" },
          evidence: rspec_evidence
        }
      ]
    end

    private

    def rspec?
      rspec_evidence.present?
    end

    def rspec_evidence
      return "spec/" if @path.join("spec").directory?
      ".rspec" if @path.join(".rspec").exist?
    end
  end
end
