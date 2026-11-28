require "rails_helper"

RSpec.describe ExternalPrBotPolicy do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:now) { Time.zone.parse("2026-11-28 12:00:00") }
  let(:client) { instance_double(GithubClient, add_issue_comment: nil) }
  let(:defaults) { SyrusYml::ExternalBotPrsConfig.default }

  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "external_pr",
      external_pr_number: 9,
      external_pr_fork: false,
      external_pr_author: "dependabot[bot]",
      branch_name: "dependabot/github_actions/actions/deploy-pages-5",
      state: "implemented"
    )
  end

  def pr(login: "dependabot[bot]", type: "Bot", head_repo: "acme/widgets", created_at: now - 2.days, head_sha: "head-1")
    {
      number: 9,
      state: "open",
      user: { login: login, type: type },
      head: { sha: head_sha, ref: job.branch_name, repo: { full_name: head_repo } },
      created_at: created_at
    }
  end

  def review(id: 11, login: "syrus-local[bot]", body: "Syrus ran required checks on this pull request before landing and the following failed:\n\n- **rspec**")
    { id: id, state: "CHANGES_REQUESTED", body: body, submitted_at: (now - 1.hour).iso8601, user: { login: login, type: "Bot" } }
  end

  def call(pull_request: pr, reviews: [ review ], config: defaults, at: now)
    described_class.call(job: job, pr: pull_request, client: client, changes_requested: reviews, now: at, config: config)
  end

  describe ".bot_author?" do
    it "reads the polled PR author's type and login" do
      expect(described_class.bot_author?(pr)).to be(true)
      expect(described_class.bot_author?(pr(login: "renovate[bot]", type: "Bot"))).to be(true)
      expect(described_class.bot_author?(pr(login: "some-app[bot]", type: "User"))).to be(true)
      expect(described_class.bot_author?(pr(login: "octocat", type: "User"))).to be(false)
      expect(described_class.bot_author?({ user: nil })).to be(false)
    end
  end

  describe ".dependency_key" do
    it "strips the version a bot branch updates to" do
      expect(described_class.dependency_key("dependabot/bundler/rack-3.1.1")).to eq("dependabot/bundler/rack")
      expect(described_class.dependency_key("dependabot/github_actions/actions/deploy-pages-5")).to eq("dependabot/github_actions/actions/deploy-pages")
      expect(described_class.dependency_key("renovate/rails-8.x")).to eq("renovate/rails")
    end
  end

  it "leaves human-authored PRs waiting for their author" do
    expect(call(pull_request: pr(login: "octocat", type: "User"))).to eq(:not_applicable)
    expect(job.workflows.where(trigger_kind: "external_pr_feedback")).to be_empty
  end

  it "leaves bot PRs from forks alone (Syrus cannot push there)" do
    expect(call(pull_request: pr(head_repo: "dependabot-fork/widgets"))).to eq(:not_applicable)
  end

  it "waits when .syrus.yml cannot be read" do
    allow(RepoDefaultBranchSyrusYml).to receive(:new).and_return(
      instance_double(RepoDefaultBranchSyrusYml, resolve: RepoDefaultBranchSyrusYml::Result.new(config: nil, source: "none", note: "rate limited", outcome: :unavailable))
    )

    expect(described_class.call(job: job, pr: pr, client: client, changes_requested: [ review ], now: now)).to eq(:config_unavailable)
  end

  it "routes requested changes on a bot PR to Syrus's own repair, once per review" do
    job.approve!(via: "operator")

    expect(call).to eq(:repair_dispatched)

    workflow = job.workflows.find_by!(trigger_kind: "external_pr_feedback")
    expect(workflow.artifact("pr_comments").first).to include("id" => 11, "author" => "syrus-local[bot]")
    expect(workflow.artifact("pr_comments").first["body"]).to include("rspec")
    expect(job.reload).not_to be_approved
    expect(job.external_pr_bot_recovery).to include("repaired_review_ids" => [ 11 ], "repair_workflow_id" => workflow.id)

    # The repair is running: the same review does not launch a second one.
    expect(call).to eq(:waiting)
    expect(job.workflows.where(trigger_kind: "external_pr_feedback").count).to eq(1)
  end

  it "waits instead of repairing when review_feedback is wait" do
    config = defaults.with(review_feedback: "wait")

    expect(call(config: config)).to eq(:waiting)
    expect(job.workflows.where(trigger_kind: "external_pr_feedback")).to be_empty
  end

  it "asks Dependabot to recreate the PR once a repair of the review failed" do
    call
    job.workflows.find_by!(trigger_kind: "external_pr_feedback").update_columns(state: "failed")

    expect(call).to eq(:refresh_requested)
    expect(client).to have_received(:add_issue_comment).with("acme/widgets", 9, "@dependabot recreate").once
    expect(job.reload.external_pr_bot_recovery).to include("refresh_count" => 1, "refresh_head_sha" => "head-1", "refresh_reason" => "repair_failed")
  end

  it "asks Dependabot to recreate a PR older than max_age_days, then waits for it" do
    old_pr = pr(created_at: now - 45.days)

    expect(call(pull_request: old_pr)).to eq(:refresh_requested)
    expect(call(pull_request: old_pr, at: now + 1.hour)).to eq(:refresh_pending)
    expect(client).to have_received(:add_issue_comment).once
    expect(job.workflows.where(trigger_kind: "external_pr_feedback")).to be_empty
  end

  it "closes the Job when Dependabot does not answer the recreate request" do
    old_pr = pr(created_at: now - 45.days)
    call(pull_request: old_pr)

    expect(call(pull_request: old_pr, at: now + 2.days)).to eq(:closed_stale)
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("external_pr_stale")
  end

  it "repairs the recreated head afresh, and closes when it goes stale again" do
    job.update_columns(external_pr_bot_recovery: { "repaired_review_ids" => [ 11 ], "refresh_requested_at" => (now - 3.hours).iso8601, "refresh_head_sha" => "head-1", "refresh_count" => 1 })
    recreated = pr(created_at: now - 45.days, head_sha: "head-2")

    expect(call(pull_request: recreated)).to eq(:repair_dispatched)
    expect(job.reload.external_pr_bot_recovery).to include("refresh_answered_head_sha" => "head-2", "repaired_review_ids" => [ 11 ])

    job.workflows.find_by!(trigger_kind: "external_pr_feedback").update_columns(state: "failed")
    expect(call(pull_request: recreated, at: now + 1.hour)).to eq(:closed_stale)
    expect(client).not_to have_received(:add_issue_comment)
  end

  it "closes a stale PR from a bot that cannot be asked to recreate it" do
    job.update!(external_pr_author: "renovate[bot]", branch_name: "renovate/rails-8.x")

    expect(call(pull_request: pr(login: "renovate[bot]", created_at: now - 45.days))).to eq(:closed_stale)
    expect(job.reload.closure_reason).to eq("external_pr_stale")
  end

  it "keeps waiting on a stale PR when stale_action is wait" do
    expect(call(pull_request: pr(created_at: now - 45.days), config: defaults.with(stale_action: "wait"))).to eq(:waiting)
    expect(job.reload).not_to be_closed
  end

  it "treats base drift beyond max_commits_behind as stale" do
    job.update_columns(commits_behind_base: 900)

    expect(call(config: defaults.with(max_commits_behind: 500, stale_action: "close"))).to eq(:closed_stale)
    expect(job.reload.external_pr_bot_recovery).to include("closed_detail" => "more_than_500_commits_behind")
  end

  it "closes the Job when the bot opened a newer PR for the same dependency" do
    newer = Job.create!(
      user: user, repository: repository, kind: "external_pr", external_pr_number: 12, external_pr_fork: false,
      external_pr_author: "dependabot[bot]", branch_name: "dependabot/github_actions/actions/deploy-pages-6", state: "implemented"
    )
    Job.create!(
      user: user, repository: repository, kind: "external_pr", external_pr_number: 13, external_pr_fork: false,
      external_pr_author: "dependabot[bot]", branch_name: "dependabot/github_actions/actions/cache-6", state: "implemented"
    )

    expect(call).to eq(:closed_superseded)
    expect(job.reload.closure_reason).to eq("external_pr_superseded")
    expect(job.external_pr_bot_recovery["closed_detail"]).to eq("superseded by #{newer.slug}")
  end

  it "does not treat a newer PR for a different dependency as superseding" do
    Job.create!(
      user: user, repository: repository, kind: "external_pr", external_pr_number: 13, external_pr_fork: false,
      external_pr_author: "dependabot[bot]", branch_name: "dependabot/github_actions/actions/cache-6", state: "implemented"
    )

    expect(call).to eq(:repair_dispatched)
  end

  describe ".bot_command?" do
    it "recognizes commands addressed to dependency bots" do
      expect(described_class.bot_command?("@dependabot recreate")).to be(true)
      expect(described_class.bot_command?("@renovate rebase please")).to be(true)
      expect(described_class.bot_command?("Please bump this @dependabot")).to be(false)
    end
  end
end
