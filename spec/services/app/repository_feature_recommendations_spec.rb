require "rails_helper"

RSpec.describe App::RepositoryFeatureRecommendations do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, ci_health: "unknown", grader_health: "unknown") }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(App::PreviewAvailability).to receive(:configured?).and_return(false)
    allow(Feature).to receive(:visual_review_enabled?).and_return(false)
    allow(client).to receive(:file_content_at).and_return(nil)
    allow(client).to receive(:file_tree_at).and_return(items: [], truncated: false)
  end

  # `.syrus.yml` and the repo file tree are read over the GitHub API (see
  # RepositoryFeatureRecommendations#syrus_yml_content / #repo_files), not
  # from the local bare clone — this service is called from the web tier,
  # which doesn't share the worker's on-disk clone. The `client:` seam
  # (mirroring RepoVisualReviewPlan's own spec) injects a double directly
  # instead of stubbing `GithubClient.for`, since `instance_double` isn't
  # `is_a?(GithubClient)`.
  def recommendations
    described_class.new(repository: repository, user: user, client: client).recommendations
  end

  def stub_syrus_yml(content)
    allow(client).to receive(:file_content_at)
      .with(repository.slug, SyrusYml::CONFIG_FILE, repository.default_branch)
      .and_return(content: content, size: content.to_s.bytesize)
  end

  def stub_repo_files(paths)
    allow(client).to receive(:file_tree_at)
      .with(repository.slug, repository.default_branch)
      .and_return(items: paths.map { |path| { path: path, size: 0 } }, truncated: false)
  end

  it "recommends visual review for browser apps without explicit visual review" do
    stub_repo_files(%w[package.json src/App.tsx])
    stub_syrus_yml("preview:\n  start: npm run dev\n")

    expect(recommendations).to include(hash_including(
      id: "visual_review",
      cta: include(kind: "job", action_id: "visual_review")
    ))
  end

  it "does not recommend visual review when the repo explicitly enabled it" do
    # Regression: this must be resolved from the GitHub-fetched config, not
    # the repository's local bare clone (which the web tier can't see) — see
    # "Deploy target" in CLAUDE.md ("Web pods don't need this volume").
    stub_repo_files(%w[package.json])
    stub_syrus_yml("preview:\n  start: npm run dev\nvisual_review:\n  enabled: true\n")

    ids = recommendations.map { |entry| entry.fetch(:id) }

    expect(ids).not_to include("visual_review")
  end

  it "recommends one-click prepare enablement when prepare is disabled" do
    repository.update!(prepare_enabled: false)

    recommendation = recommendations.find { |entry| entry.fetch(:id) == "syrus_prepare" }

    expect(recommendation).to include(cta: include(kind: "toggle", action_id: "enable_prepare"))
  end

  it "does not recommend pinning prepare commands when they are already configured" do
    stub_syrus_yml("prepare:\n  - bundle install\n")

    ids = recommendations.map { |entry| entry.fetch(:id) }

    expect(ids).not_to include("syrus_prepare")
  end

  it "recommends a server-owned CI setup job when CI is not configured and no workflow exists" do
    repository.update!(ci_health: "not_configured")
    stub_repo_files(%w[Gemfile])

    recommendation = recommendations.find { |entry| entry.fetch(:id) == "github_actions_ci" }

    expect(recommendation).to include(cta: include(kind: "job", action_id: "github_actions_ci"))
  end

  it "does not recommend GitHub Actions when a workflow already exists" do
    repository.update!(ci_health: "not_configured")
    stub_repo_files([".github/workflows/ci.yml"])

    ids = recommendations.map { |entry| entry.fetch(:id) }

    expect(ids).not_to include("github_actions_ci")
  end

  it "does not recommend delivery tracks when they are already configured" do
    repository.update!(default_branch: "release")
    stub_syrus_yml("delivery:\n  promotion:\n    enabled: true\n")

    ids = recommendations.map { |entry| entry.fetch(:id) }

    expect(ids).not_to include("delivery_tracks")
  end

  it "limits the banner stack to three ordered recommendations" do
    repository.update!(prepare_enabled: false, pr_cost_footer_enabled: false, ci_health: "not_configured")
    allow(App::PreviewAvailability).to receive(:configured?).and_return(true)
    stub_repo_files(%w[package.json])
    stub_syrus_yml("preview:\n  start: npm run dev\n")

    expect(recommendations.size).to eq(3)
    expect(recommendations.map { |entry| entry.fetch(:id) }).to eq(%w[visual_review preview_seed_data syrus_prepare])
  end

  it "resolves prompt templates for job actions without client-provided prompt text" do
    action = described_class.job_action("github_actions_ci")

    expect(action.fetch(:title)).to eq("Add GitHub Actions CI")
    expect(action.fetch(:prompt)).to include("CI")
  end
end
