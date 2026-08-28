require "rails_helper"
require "ostruct"

RSpec.describe Jobs::LandedCommitsBackfill do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil, warn: nil) }
  let(:clone_path) { Pathname.new("/tmp/acme-widgets-bare") }
  let(:git) { instance_double(GitRunner) }
  let(:bare_clone) { instance_double(RepositoryBareClone, sync!: nil, path: clone_path) }

  def landed_job(pr_number:, landed_sha:, issue_number: pr_number)
    Job.create!(
      user: user, repository: repository, issue_number: issue_number,
      state: "closed", closure_reason: "pr_merged",
      pr_number: pr_number, landed_sha: landed_sha, finished_at: Time.current
    )
  end

  def commit_double(sha:, message:)
    OpenStruct.new(sha: sha, commit: OpenStruct.new(message: message))
  end

  def service_for(clients_by_pr:, **opts)
    client_factory = ->(job) { clients_by_pr.fetch(job.pr_number) }
    described_class.new(
      repository: repository, client_factory: client_factory,
      git: git, bare_clone: bare_clone, logger: logger, **opts
    )
  end

  def github_client(commits)
    double("GithubClient", pr_commits: commits)
  end

  describe "regular Jobs" do
    it "records a multi-commit Job in original commit order" do
      job = landed_job(pr_number: 501, landed_sha: "mergedsha1")
      client = github_client([
        commit_double(sha: "orig1", message: "First"),
        commit_double(sha: "orig2", message: "Second"),
        commit_double(sha: "orig3", message: "Third")
      ])
      allow(git).to receive(:run)
        .with("log", "--first-parent", "--reverse", "-n", "3", "--pretty=format:%H", "mergedsha1", chdir: clone_path.to_s)
        .and_return("sha1\nsha2\nsha3\n")

      result = service_for(clients_by_pr: { 501 => client }).call

      expect(result.checked).to eq(1)
      expect(result.recorded).to eq(1)
      expect(result.commits_recorded).to eq(3)
      expect(result.skipped).to eq(0)
      expect(result.errors).to eq(0)

      rows = LandedCommit.where(landable: job).order(:position)
      expect(rows.pluck(:sha)).to eq(%w[sha1 sha2 sha3])
      expect(rows.pluck(:kind).uniq).to eq([ "implementation" ])
      expect(rows.pluck(:position)).to eq([ 0, 1, 2 ])
    end

    it "is idempotent: a second run skips a Job that already has LandedCommit rows" do
      landed_job(pr_number: 501, landed_sha: "mergedsha1")
      client = github_client([ commit_double(sha: "orig1", message: "First") ])
      allow(git).to receive(:run)
        .with("log", "--first-parent", "--reverse", "-n", "1", "--pretty=format:%H", "mergedsha1", chdir: clone_path.to_s)
        .and_return("sha1\n")

      service = service_for(clients_by_pr: { 501 => client })
      service.call
      result = service.call

      expect(result.checked).to eq(1)
      expect(result.recorded).to eq(0)
      expect(result.skipped).to eq(1)
      expect(LandedCommit.count).to eq(1)
    end

    it "logs and skips a Job when the GitHub API call fails, without aborting the run" do
      landed_job(pr_number: 501, landed_sha: "mergedsha1")
      client = double("GithubClient")
      allow(client).to receive(:pr_commits).and_raise(Octokit::NotFound.new)

      result = service_for(clients_by_pr: { 501 => client }).call

      expect(result.checked).to eq(1)
      expect(result.errors).to eq(1)
      expect(LandedCommit.count).to eq(0)
    end
  end

  describe "merge-train landings" do
    def build_train(epic: nil, priority: nil)
      MergeTrain.create!(
        epic: epic, repository: repository, base_branch: "main",
        priority: priority, state: "succeeded",
        integration_branch: "syrus/merge-train-x", integration_sha: "mergesha",
        finished_at: Time.current
      )
    end

    def stub_two_parents(sha: "mergesha", base: "basesha", integration: "intsha")
      allow(git).to receive(:run)
        .with("log", "-1", "--pretty=format:%P", sha, chdir: clone_path.to_s)
        .and_return("#{base} #{integration}\n")
    end

    def stub_ranged_log(entries, base: "basesha", integration: "intsha")
      body = entries.map { |sha, subject| "#{sha}\x1f#{subject}" }.join("\n")
      allow(git).to receive(:run)
        .with("log", "--reverse", "--pretty=format:%H%x1f%s", "#{base}..#{integration}", chdir: clone_path.to_s)
        .and_return(body)
    end

    it "splits a 2+ member epic-backed train's commits per member with no cross-member bleed" do
      epic = Factories.epic(user: user, repository: repository)
      job_a = landed_job(pr_number: 601, landed_sha: "mergesha", issue_number: 1)
      job_b = landed_job(pr_number: 602, landed_sha: "mergesha", issue_number: 2)
      train = build_train(epic: epic)
      MergeTrainMember.create!(merge_train: train, job: job_a, position: 0)
      MergeTrainMember.create!(merge_train: train, job: job_b, position: 1)

      stub_two_parents
      stub_ranged_log([
        [ "shaA1", "Subject A1" ],
        [ "shaA2", "Subject A2" ],
        [ "shaB1", "Subject B1" ]
      ])
      client_a = github_client([
        commit_double(sha: "origA1", message: "Subject A1"),
        commit_double(sha: "origA2", message: "Subject A2")
      ])
      client_b = github_client([ commit_double(sha: "origB1", message: "Subject B1") ])

      result = service_for(clients_by_pr: { 601 => client_a, 602 => client_b }).call

      expect(result.checked).to eq(1)
      expect(result.recorded).to eq(1)
      expect(result.commits_recorded).to eq(4) # 2 + 1 member commits + 1 integration merge
      expect(result.errors).to eq(0)

      a_rows = LandedCommit.where(landable: job_a).order(:position)
      expect(a_rows.pluck(:sha)).to eq(%w[shaA1 shaA2])
      expect(a_rows.pluck(:kind).uniq).to eq([ "implementation" ])

      b_rows = LandedCommit.where(landable: job_b).order(:position)
      expect(b_rows.pluck(:sha)).to eq(%w[shaB1])

      merge_row = LandedCommit.find_by(landable: epic, kind: "integration_merge")
      expect(merge_row.sha).to eq("mergesha")
      expect(LandedCommit.where(landable: epic, kind: "reconcile")).to be_empty
    end

    it "records a bundle-backed train's integration merge against the MergeTrain, not an Epic" do
      job_a = landed_job(pr_number: 701, landed_sha: "mergesha", issue_number: 1)
      train = build_train(priority: "medium")
      MergeTrainMember.create!(merge_train: train, job: job_a, position: 0)

      stub_two_parents
      stub_ranged_log([ [ "shaA1", "Subject A1" ] ])
      client_a = github_client([ commit_double(sha: "origA1", message: "Subject A1") ])

      service_for(clients_by_pr: { 701 => client_a }).call

      a_rows = LandedCommit.where(landable: job_a).order(:position)
      expect(a_rows.pluck(:sha)).to eq(%w[shaA1])

      merge_row = LandedCommit.find_by(kind: "integration_merge")
      expect(merge_row.landable).to eq(train)
      expect(merge_row.landable_type).to eq("MergeTrain")
    end

    it "records the leftover commit as a reconcile row when the range has more commits than the members" do
      epic = Factories.epic(user: user, repository: repository)
      job_a = landed_job(pr_number: 601, landed_sha: "mergesha", issue_number: 1)
      train = build_train(epic: epic)
      MergeTrainMember.create!(merge_train: train, job: job_a, position: 0)

      stub_two_parents
      stub_ranged_log([
        [ "shaA1", "Subject A1" ],
        [ "shaR1", "Reconcile subject" ]
      ])
      client_a = github_client([ commit_double(sha: "origA1", message: "Subject A1") ])

      result = service_for(clients_by_pr: { 601 => client_a }).call

      expect(result.commits_recorded).to eq(3) # 1 member commit + 1 reconcile + 1 integration merge
      reconcile_row = LandedCommit.find_by(landable: epic, kind: "reconcile")
      expect(reconcile_row.sha).to eq("shaR1")
      expect(reconcile_row.position).to eq(0)
    end

    it "is idempotent: a second run skips a train that already has LandedCommit rows" do
      epic = Factories.epic(user: user, repository: repository)
      job_a = landed_job(pr_number: 601, landed_sha: "mergesha", issue_number: 1)
      train = build_train(epic: epic)
      MergeTrainMember.create!(merge_train: train, job: job_a, position: 0)

      stub_two_parents
      stub_ranged_log([ [ "shaA1", "Subject A1" ] ])
      client_a = github_client([ commit_double(sha: "origA1", message: "Subject A1") ])

      service = service_for(clients_by_pr: { 601 => client_a })
      service.call
      result = service.call

      expect(result.checked).to eq(1)
      expect(result.recorded).to eq(0)
      expect(result.skipped).to eq(1)
      expect(LandedCommit.count).to eq(2) # member commit + integration merge, not duplicated
    end
  end

  it "supports dry runs without writing any LandedCommit rows" do
    landed_job(pr_number: 501, landed_sha: "mergedsha1")
    client = github_client([ commit_double(sha: "orig1", message: "First") ])
    allow(git).to receive(:run)
      .with("log", "--first-parent", "--reverse", "-n", "1", "--pretty=format:%H", "mergedsha1", chdir: clone_path.to_s)
      .and_return("sha1\n")

    result = service_for(clients_by_pr: { 501 => client }).call(dry_run: true)

    expect(result.recorded).to eq(1)
    expect(result.commits_recorded).to eq(1)
    expect(LandedCommit.count).to eq(0)
  end
end
