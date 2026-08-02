require "rails_helper"

RSpec.describe JobStackPreparedBaseBuilder do
  let(:user) { Factories.user(github_token: "token") }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:epic) { Factories.epic(user: user, repository: repository, state: "in_progress", epic_dependency_policy: "nonlinear") }
  let(:job) { Factories.job_record(user: user, repository: repository, epic: epic, state: "queued", issue_number: 1577) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:git) { FakeGit.new }

  before do
    ENV["SYRUS_DATA_ROOT"] = Dir.mktmpdir("syrus-prepared-base-spec")
    allow(repository).to receive(:authenticated_url).and_return("https://example.test/repo.git")
    allow(repository).to receive(:authenticated_push_url).and_return("https://example.test/repo.git")
    allow(repository).to receive(:remote_url).and_return("https://example.test/repo.git")
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
  end

  after do
    FileUtils.rm_rf(ENV["SYRUS_DATA_ROOT"]) if ENV["SYRUS_DATA_ROOT"]
    ENV.delete("SYRUS_DATA_ROOT")
  end

  it "merges dependency branches in deterministic topological order and reports the prepared branch" do
    dep_a = approved_dependency(1574, "syrus/issue-1574", "a" * 40)
    dep_b = approved_dependency(1575, "syrus/issue-1575", "b" * 40)
    dep_c = approved_dependency(1576, "syrus/issue-1576", "c" * 40)
    JobDependency.create!(job: dep_c, depends_on_job: dep_a, source: "manual")
    [ dep_a, dep_b, dep_c ].each { |dependency| git.branch_shas[dependency.branch_name] = dependency.head_sha }

    result = described_class.new(job, workflow, git: git).call([ dep_c, dep_b, dep_a ])

    expect(result).to be_succeeded
    expect(result.branch_name).to eq("syrus/prepared-base-#{job.id}-#{workflow.id}")
    expect(result.head_sha).to eq("p" * 40)
    expect(git.merged_refs).to eq([
      "refs/remotes/origin/syrus/issue-1574",
      "refs/remotes/origin/syrus/issue-1575",
      "refs/remotes/origin/syrus/issue-1576"
    ])
    expect(git.pushed_refs).to include("HEAD:refs/heads/syrus/prepared-base-#{job.id}-#{workflow.id}")
  end

  def approved_dependency(issue_number, branch_name, head_sha)
    dependency = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "approved",
      issue_number: issue_number,
      branch_name: branch_name,
      pr_number: issue_number
    )
    dependency.runs.create!(trigger_kind: "initial", state: "succeeded", head_sha: head_sha)
    dependency
  end

  class FakeGit
    attr_reader :branch_shas, :merged_refs, :pushed_refs

    def initialize
      @branch_shas = {}
      @merged_refs = []
      @pushed_refs = []
    end

    def run(*args, chdir: nil, env: {}, timeout: nil)
      case args.first
      when "merge"
        merged_refs << args.last
      when "push"
        pushed_refs << args.last
      when "rev-parse"
        return rev_parse(args.second)
      end

      ""
    end

    def configure_author(_identity, chdir:)
      nil
    end

    private

    def rev_parse(ref)
      return "p" * 40 if ref == "HEAD"

      branch = ref.to_s.delete_prefix("refs/remotes/origin/")
      branch_shas.fetch(branch)
    end
  end
end
