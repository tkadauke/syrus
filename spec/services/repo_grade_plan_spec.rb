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

    it "ignores entries with unsafe or duplicate names" do
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

      expect(described_class.for(@dir).graders.map(&:command)).to eq([ "bin/rspec" ])
    end

    it "returns an empty plan when grade steps are absent" do
      write(".syrus.yml", "prepare: []\n")

      result = described_class.for(@dir)

      expect(result.graders).to be_empty
      expect(result.note).to eq("no graders configured")
    end
  end

  def write(rel, contents)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
end
