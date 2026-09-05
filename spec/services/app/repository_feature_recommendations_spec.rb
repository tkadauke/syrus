require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::RepositoryFeatureRecommendations do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, ci_health: "unknown", grader_health: "unknown") }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  before do
    allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(false)
    allow(Feature).to receive(:visual_review_enabled?).and_return(false)
  end

  def write_bare_clone(files: {}, syrus_yml: nil)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml) if syrus_yml
    files.each do |path, content|
      full_path = File.join(work_dir, path)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, content)
    end
    File.write(File.join(work_dir, "README.md"), "hi") if Dir.children(work_dir).reject { |name| name == ".git" }.empty?
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  it "recommends visual review for browser apps without explicit visual review" do
    write_bare_clone(
      files: { "package.json" => "{}\n", "src/App.tsx" => "export function App() { return null }\n" },
      syrus_yml: "preview:\n  start: npm run dev\n"
    )

    recommendations = described_class.for(repository: repository, user: user)

    expect(recommendations).to include(hash_including(
      id: "visual_review",
      cta: include(kind: "job", action_id: "visual_review")
    ))
  end

  it "does not recommend visual review when the repo explicitly enabled it" do
    write_bare_clone(
      files: { "package.json" => "{}\n" },
      syrus_yml: "preview:\n  start: npm run dev\nvisual_review:\n  enabled: true\n"
    )

    ids = described_class.for(repository: repository, user: user).map { |entry| entry.fetch(:id) }

    expect(ids).not_to include("visual_review")
  end

  it "recommends one-click prepare enablement when prepare is disabled" do
    repository.update!(prepare_enabled: false)
    write_bare_clone(files: { "README.md" => "hi\n" })

    recommendation = described_class.for(repository: repository, user: user).find { |entry| entry.fetch(:id) == "syrus_prepare" }

    expect(recommendation).to include(cta: include(kind: "toggle", action_id: "enable_prepare"))
  end

  it "recommends a server-owned CI setup job when CI is not configured and no workflow exists" do
    repository.update!(ci_health: "not_configured")
    write_bare_clone(files: { "Gemfile" => "source 'https://rubygems.org'\n" })

    recommendation = described_class.for(repository: repository, user: user).find { |entry| entry.fetch(:id) == "github_actions_ci" }

    expect(recommendation).to include(cta: include(kind: "job", action_id: "github_actions_ci"))
  end

  it "does not recommend GitHub Actions when a workflow already exists" do
    repository.update!(ci_health: "not_configured")
    write_bare_clone(files: { ".github/workflows/ci.yml" => "name: CI\n" })

    ids = described_class.for(repository: repository, user: user).map { |entry| entry.fetch(:id) }

    expect(ids).not_to include("github_actions_ci")
  end

  it "limits the banner stack to three ordered recommendations" do
    repository.update!(prepare_enabled: false, pr_cost_footer_enabled: false, ci_health: "not_configured")
    write_bare_clone(files: { "package.json" => "{}\n" }, syrus_yml: "preview:\n  start: npm run dev\n")

    recommendations = described_class.for(repository: repository, user: user)

    expect(recommendations.size).to eq(3)
    expect(recommendations.map { |entry| entry.fetch(:id) }).to eq(%w[visual_review preview_seed_data syrus_prepare])
  end


  it "resolves prompt templates for job actions without client-provided prompt text" do
    action = described_class.job_action("github_actions_ci")

    expect(action.fetch(:title)).to eq("Add GitHub Actions CI")
    expect(action.fetch(:prompt)).to include("CI")
  end
end
