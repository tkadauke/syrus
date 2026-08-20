require "rails_helper"
require "tmpdir"

RSpec.describe RepoGradeSignals do
  around do |ex|
    Dir.mktmpdir("syrus-repo-grade-signals") { |dir| @dir = dir; ex.run }
  end

  def write(rel, contents = "")
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def candidate_names(result)
    result.candidates.map(&:name)
  end

  describe ".for" do
    it "detects nothing in an empty repository" do
      result = described_class.for(@dir)

      expect(result.candidates).to be_empty
      expect(result.ci_workflow_paths).to be_empty
      expect(result.ci_run_commands).to be_empty
    end

    context "with a Ruby-only fixture repo" do
      it "detects rspec and rubocop, not any Node/Python/Go tooling" do
        write("spec/spec_helper.rb")
        write(".rubocop.yml", "AllCops:\n  NewCops: enable\n")

        result = described_class.for(@dir)

        expect(candidate_names(result)).to contain_exactly("rspec", "rubocop")
        rspec = result.candidates.find { |c| c.name == "rspec" }
        expect(rspec.run).to eq("bin/rspec")
        expect(rspec.evidence).to eq("spec/")
        expect(rspec.required).to be(true)
        expect(rspec.timeout_minutes).to eq(15)
      end

      it "detects rspec from a bare .rspec file with no spec/ directory" do
        write(".rspec", "--color\n")

        result = described_class.for(@dir)

        rspec = result.candidates.find { |c| c.name == "rspec" }
        expect(rspec.evidence).to eq(".rspec")
      end

      it "detects pytest from a pyproject.toml ini_options section" do
        write("pyproject.toml", "[tool.pytest.ini_options]\ntestpaths = [\"tests\"]\n")

        result = described_class.for(@dir)

        expect(candidate_names(result)).to contain_exactly("pytest")
        expect(result.candidates.first.evidence).to eq("pyproject.toml [tool.pytest.ini_options]")
      end

      it "does not detect pytest from an unrelated pyproject.toml" do
        write("pyproject.toml", "[tool.poetry]\nname = \"widgets\"\n")

        result = described_class.for(@dir)

        expect(candidate_names(result)).to be_empty
      end

      it "detects pytest from a setup.cfg [tool:pytest] section" do
        write("setup.cfg", "[tool:pytest]\ntestpaths = tests\n")

        result = described_class.for(@dir)

        expect(candidate_names(result)).to contain_exactly("pytest")
      end
    end

    context "with a Node-only fixture repo" do
      it "detects jest, eslint, and typecheck" do
        write("jest.config.js", "module.exports = {}\n")
        write(".eslintrc.json", "{}\n")
        write("tsconfig.json", "{}\n")
        write("package.json", "{}\n")

        result = described_class.for(@dir)

        expect(candidate_names(result)).to contain_exactly("jest", "eslint", "typecheck")
      end
    end

    context "with a Go fixture repo" do
      it "detects go-test only when a _test.go file is also present" do
        write("go.mod", "module example.com/widgets\n")

        expect(candidate_names(described_class.for(@dir))).to be_empty

        write("main_test.go", "package main\n")

        expect(candidate_names(described_class.for(@dir))).to contain_exactly("go-test")
      end
    end

    context "with a mixed Ruby + Node fixture repo" do
      it "detects tooling from both ecosystems together" do
        write("spec/spec_helper.rb")
        write(".rubocop.yml")
        write("jest.config.ts", "export default {}\n")
        write(".eslintrc.yml")

        result = described_class.for(@dir)

        expect(candidate_names(result)).to contain_exactly("rspec", "rubocop", "jest", "eslint")
      end
    end

    context "with existing CI config" do
      it "lists workflow file paths and extracts run: step commands" do
        write(".github/workflows/ci.yml", <<~YAML)
          name: CI
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              steps:
                - uses: actions/checkout@v4
                - run: bundle install
                - run: bin/rspec-ci
        YAML

        result = described_class.for(@dir)

        expect(result.ci_workflow_paths).to eq([ ".github/workflows/ci.yml" ])
        expect(result.ci_run_commands).to contain_exactly("bundle install", "bin/rspec-ci")
      end

      it "deduplicates identical run: commands across workflow files" do
        write(".github/workflows/a.yml", <<~YAML)
          jobs:
            test:
              steps:
                - run: bin/test
        YAML
        write(".github/workflows/b.yaml", <<~YAML)
          jobs:
            test:
              steps:
                - run: bin/test
        YAML

        result = described_class.for(@dir)

        expect(result.ci_workflow_paths).to eq([ ".github/workflows/a.yml", ".github/workflows/b.yaml" ])
        expect(result.ci_run_commands).to eq([ "bin/test" ])
      end

      it "does not raise on an unparsable workflow file" do
        write(".github/workflows/broken.yml", "not: [valid: yaml\n")

        result = described_class.for(@dir)

        expect(result.ci_workflow_paths).to eq([ ".github/workflows/broken.yml" ])
        expect(result.ci_run_commands).to be_empty
      end
    end
  end

  describe "RULE_DESCRIPTIONS" do
    it "declares a name/run/signals description for every detected rule" do
      names = described_class::RULE_DESCRIPTIONS.map(&:name)

      expect(names).to contain_exactly("rspec", "jest", "pytest", "go-test", "rubocop", "eslint", "typecheck")
      described_class::RULE_DESCRIPTIONS.each do |rule|
        expect(rule.run).to be_present
        expect(rule.signals).to be_present
      end
    end
  end
end
