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
          run: "type: rspec",
          type: "rspec",
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
