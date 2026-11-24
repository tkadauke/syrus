require "rails_helper"
require "tmpdir"

# The "Test coverage" section of the agent environment snapshot is this
# plugin's contribution through :line_coverage_provider.
RSpec.describe AgentEnvironmentSnapshot do
  around do |example|
    Dir.mktmpdir("syrus-agent-env") do |dir|
      @workspace_path = Pathname.new(dir)
      example.run
    end
  end

  describe "coverage section" do
    def run_with_coverage_yml(coverage_yml_fragment, &block)
      repo = Factories.repository(owner: "rome", name: "aqueduct", default_branch: "main")
      job = Factories.job(repository: repo)
      workflow = job.workflows.last
      step = workflow.steps.find_by!(kind: "implement")
      run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, iteration: 1)

      @workspace_path.join(".syrus.yml").write(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
          #{coverage_yml_fragment}
      YAML

      block.call(run, workflow)
    end

    it "includes the coverage section when coverage is configured and an artifact is present" do
      run_with_coverage_yml("threshold:\n    lines: 80\n    pr_lines: 90\n  on_miss: warn") do |run, workflow|
        SyrusCoverage::Artifact.write!(workflow, {
          "summary"        => { "lines_pct" => 74.2, "branches_pct" => 68.1 },
          "threshold_miss" => false
        })

        snapshot = described_class.for_run(run, workspace_path: @workspace_path)

        expect(snapshot).to include("## Test coverage")
        expect(snapshot).to include("Configured: lines ≥80%, PR delta ≥90% (on_miss: warn)")
        expect(snapshot).to match(/Last run: lines 74\.2%, branches 68\.1% \(#{workflow.slug},/)
      end
    end

    it "omits the coverage section when no coverage key is in .syrus.yml" do
      repo = Factories.repository(owner: "rome", name: "aqueduct", default_branch: "main")
      job = Factories.job(repository: repo)
      step = job.workflows.last.steps.find_by!(kind: "implement")
      run = step.runs.create!(job: job, trigger_kind: "initial", iteration: 1)

      @workspace_path.join(".syrus.yml").write(<<~YAML)
        prepare:
          - bundle install
      YAML

      snapshot = described_class.for_run(run, workspace_path: @workspace_path)

      expect(snapshot).not_to include("## Test coverage")
    end

    it "shows the threshold miss warning when threshold_miss is true" do
      run_with_coverage_yml("threshold:\n    lines: 80\n  on_miss: warn") do |run, workflow|
        SyrusCoverage::Artifact.write!(workflow, {
          "summary"               => { "lines_pct" => 74.2 },
          "threshold_miss"        => true,
          "threshold_miss_details" => {
            "lines_pct"       => 74.2,
            "threshold_lines" => 80.0,
            "pr_delta_pct"    => nil,
            "threshold_pr_lines" => nil
          }
        })

        snapshot = described_class.for_run(run, workspace_path: @workspace_path)

        expect(snapshot).to include("⚠️  Threshold miss: lines 74.2% < 80%")
      end
    end

    it "shows low-coverage changed files when diff_annotations has uncovered lines" do
      run_with_coverage_yml("on_miss: warn") do |run, workflow|
        SyrusCoverage::Artifact.write!(workflow, {
          "summary"          => { "lines_pct" => 80.0 },
          "files"            => {
            "app/services/payment_processor.rb" => { "lines_pct" => 34.0 },
            "app/models/ledger_entry.rb"        => { "lines_pct" => 41.0 }
          },
          "diff_annotations" => {
            "app/services/payment_processor.rb" => {
              "10" => "uncovered", "11" => "uncovered", "12" => "uncovered",
              "13" => "uncovered", "14" => "uncovered", "20" => "covered"
            },
            "app/models/ledger_entry.rb" => {
              "5" => "uncovered", "6" => "uncovered", "7" => "covered"
            }
          },
          "threshold_miss"   => false
        })

        snapshot = described_class.for_run(run, workspace_path: @workspace_path)

        expect(snapshot).to include("Low-coverage changed files:")
        expect(snapshot).to include("app/services/payment_processor.rb (34% — 5 uncovered changed lines)")
        expect(snapshot).to include("app/models/ledger_entry.rb (41% — 2 uncovered changed lines)")
      end
    end

    it "shows 'no coverage data yet' when coverage is configured but no artifact exists" do
      run_with_coverage_yml("on_miss: warn") do |run, _workflow|
        snapshot = described_class.for_run(run, workspace_path: @workspace_path)

        expect(snapshot).to include("## Test coverage")
        expect(snapshot).to include("Last run: no coverage data yet")
      end
    end
  end

  it "omits the section while the plugin is disabled" do
    PluginRecord.find_or_create_by!(name: "syrus_coverage").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    repo = Factories.repository(owner: "rome", name: "aqueduct", default_branch: "main")
    job = Factories.job(repository: repo)
    run = job.workflows.last.steps.find_by!(kind: "implement").runs.create!(job: job, trigger_kind: "initial", iteration: 1)
    @workspace_path.join(".syrus.yml").write("coverage:\n  sources:\n    - artifact: coverage/lcov.info\n      format: lcov\n")

    expect(described_class.for_run(run, workspace_path: @workspace_path)).not_to include("## Test coverage")
  ensure
    PluginRecord.find_by(name: "syrus_coverage")&.update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end
end
