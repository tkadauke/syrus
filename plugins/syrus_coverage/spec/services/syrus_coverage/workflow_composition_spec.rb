require "rails_helper"

# Where coverage sits in the chain: once, after the review and grade loops,
# present only for a repository that configures `coverage:`, absent (without an
# error) when the plugin is disabled.
RSpec.describe "Coverage workflow composition" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }
  let(:coverage_yml) do
    SyrusYml.new(<<~YAML).parse
      coverage:
        sources:
          - artifact: coverage/lcov.info
            format: lcov
    YAML
  end
  let(:plain_yml) { SyrusYml.new("grade: []\n").parse }
  let(:configured) { false }

  before do
    config = configured ? coverage_yml : plain_yml
    allow(RepoDefaultBranchSyrusYml).to receive(:for_job).and_return(
      RepoDefaultBranchSyrusYml::Result.new(config: config, source: ".syrus.yml", note: nil)
    )
    allow(RepoAdversarialReviewPlan).to receive(:from_syrus_yml).and_return(
      RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "disabled", criteria: [])
    )
    allow(RepoGradeLoopPlan).to receive(:from_syrus_yml).and_return(
      RepoGradeLoopPlan::Result.new(format_configured: true, generate_configured: true, graders_configured: true, source: ".syrus.yml", note: nil)
    )
  end

  # Other plugins' review loops are not what is under test.
  def kinds(workflow_class, for_job: job)
    workflow_class.instantiate(job: for_job).steps.order(:position).pluck(:kind).reject { |kind| kind.end_with?("_review") }
  end

  context "when the repository configures coverage" do
    let(:configured) { true }

    it "places the analysis after the grade loop and before dependency_audit, and the comment after pr_open" do
      expect(kinds(Workflows::Initial)).to eq(
        %w[ prepare implement format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open coverage_pr_comment ]
      )
    end

    it "keeps the analysis out of the grade loop on every chain that builds one" do
      [ Workflows::Initial, Workflows::Retry, Workflows::PrFeedback, Workflows::ChatFeedback ].each do |workflow_class|
        steps = workflow_class.steps_for(job)
        looped = steps.select { |node| node.respond_to?(:steps) }.flat_map { |node| Array(node.steps).flatten.map(&:to_s) }

        expect(looped).not_to include("coverage_analyze", "coverage_pr_comment")
        expect(steps.flatten.map(&:to_s)).to include("coverage_analyze")
      end
    end

    it "gives feedback workflows the analysis before the push and the comment after it" do
      pr_job = Factories.job_record(user: user, repository: repository, state: "implemented", pr_number: 7)

      pr_comment = kinds(Workflows::PrFeedback, for_job: pr_job)

      expect(pr_comment.index("coverage_analyze")).to be < pr_comment.index("summarize_amend")
      expect(pr_comment.last).to eq("coverage_pr_comment")
    end

    it "persists the contribution in the chain template so an in-flight workflow keeps its shape" do
      workflow = Workflows::Initial.instantiate(job: job)

      template = workflow.chain_template.to_json
      expect(template).to include('"kind":"coverage_analyze"', '"kind":"coverage_pr_comment"')
    end
  end

  context "when the repository does not configure coverage" do
    it "adds neither step" do
      expect(kinds(Workflows::Initial)).not_to include("coverage_analyze", "coverage_pr_comment")
    end
  end

  context "when the plugin is disabled" do
    let(:configured) { true }

    before do
      PluginRecord.find_or_create_by!(name: "syrus_coverage").update!(enabled: false)
      Syrus::PluginRegistry.clear_plugin_record_cache!
    end

    after do
      PluginRecord.find_by(name: "syrus_coverage")&.update!(enabled: true)
      Syrus::PluginRegistry.clear_plugin_record_cache!
    end

    it "builds the chain without the steps and without raising, even for a configured repository" do
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).and_return(
        RepoDefaultBranchSyrusYml::Result.new(config: SyrusYml.new("coverage:\n  on_miss: panic\n").parse, source: ".syrus.yml", note: nil)
      )

      expect(kinds(Workflows::Initial)).to eq(
        %w[ prepare implement format generate grader_fanout grader_collect dependency_audit summarize test_plan pr_open ]
      )
    end
  end
end
