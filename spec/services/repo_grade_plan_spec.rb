require "rails_helper"
require "tmpdir"

RSpec.describe RepoGradePlan do
  around do |ex|
    Dir.mktmpdir("syrus-repo-grade") { |dir| @dir = dir; ex.run }
  end

  describe ".for" do
    it "parses grade.steps hash form" do
      write(".syrus.yml", <<~YAML)
        grade:
          steps:
            - name: tests
              run: bin/rspec
            - name: audit
              run: bin/bundler-audit
              required: false
              timeout_minutes: 5
      YAML

      result = described_class.for(@dir)

      expect(result.graders.map(&:name)).to eq(%w[tests audit])
      expect(result.graders.map(&:command)).to eq([ "bin/rspec", "bin/bundler-audit" ])
      expect(result.graders.map(&:required)).to eq([ true, false ])
      expect(result.graders.map(&:timeout_minutes)).to eq([ 15, 5 ])
    end

    it "coerces string boolean values the same way SyrusYml does" do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: advisory
            run: bin/rubocop
            required: "false"
      YAML

      expect(described_class.for(@dir).graders.first.required).to be(false)
    end

    it "captures the optional description field for surfacing in UI + agent prompts" do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: tests
            run: bin/rspec
            description: |
              Full RSpec suite. Tests are not optional — every PR
              must include tests for the behavior it changes.
          - name: no-desc
            run: bin/no-description-grader
      YAML

      graders = described_class.for(@dir).graders

      tests = graders.find { |g| g.name == "tests" }
      expect(tests.description).to start_with("Full RSpec suite.")
      expect(tests.description).to include("Tests are not optional")

      no_desc = graders.find { |g| g.name == "no-desc" }
      expect(no_desc.description).to be_nil
    end

    it "parses shorthand array form and caps timeouts" do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: slow-tests
            run: bin/rspec
            timeout_minutes: 45
      YAML

      grader = described_class.for(@dir).graders.first

      expect(grader.name).to eq("slow-tests")
      expect(grader.timeout_minutes).to eq(30)
    end

    it "returns an empty parse-error plan for unsafe or duplicate names" do
      write(".syrus.yml", <<~YAML)
        grade:
          steps:
            - name: tests
              run: bin/rspec
            - name: ../secrets
              run: cat /etc/passwd
            - name: tests
              run: echo duplicate
      YAML

      result = described_class.for(@dir)

      expect(result.graders).to be_empty
      expect(result.note).to match(/must match/)
    end

    it "returns an empty plan when grade steps are absent" do
      write(".syrus.yml", "prepare: []\n")

      result = described_class.for(@dir)

      expect(result.graders).to be_empty
      expect(result.note).to eq("no graders configured")
    end

    it "returns an empty plan when .syrus.yml is missing" do
      result = described_class.for(@dir)

      expect(result.graders).to be_empty
      expect(result.source).to eq("none")
      expect(result.note).to eq("no .syrus.yml")
    end

    it "returns an empty parse-error plan for invalid YAML" do
      write(".syrus.yml", "grade:\n  - name: tests\n    run: [\n")

      result = described_class.for(@dir)

      expect(result.graders).to be_empty
      expect(result.source).to eq(".syrus.yml")
      expect(result.note).to match(/YAML parse error/)
    end

    it "exposes normalized max_iterations" do
      write(".syrus.yml", <<~YAML)
        grade:
          max_iterations: 2
          steps:
            - name: tests
              run: bin/rspec
      YAML

      expect(described_class.for(@dir).max_iterations).to eq(2)
    end
  end

  def write(rel, contents)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
end
