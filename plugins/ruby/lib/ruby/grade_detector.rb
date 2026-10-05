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
      if rspec?
        return [
          {
            name: "rspec",
            run: "type: rspec",
            type: "rspec",
            evidence: rspec_evidence
          }
        ]
      end

      return [] unless minitest?

      [
        {
          name: "minitest",
          run: "type: minitest",
          type: "minitest",
          evidence: minitest_evidence
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

    def minitest?
      minitest_evidence.present?
    end

    def minitest_evidence
      return "test/test_helper.rb" if @path.join("test/test_helper.rb").exist?
      return "test/" if @path.join("test").directory? && Dir.glob(@path.join("test/**/*_test.rb").to_s).any?

      gemfile = @path.join("Gemfile")
      return unless gemfile.file?

      contents = gemfile.read
      "Gemfile minitest dependency" if contents.match?(/gem\s+["']minitest["']/)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end
  end
end
