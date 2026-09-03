require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "API: repository recommendations", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", ci_health: "not_configured") }

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

  def parse_body
    JSON.parse(response.body)
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

  it "includes recommended actions in the repository detail payload" do
    write_bare_clone(files: { "Gemfile" => "source 'https://rubygems.org'\n" })
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["recommended_actions"]).to include(include(
      "id" => "syrus_prepare",
      "dismissal_key" => "repository:#{repository.id}:feature_recommendation:syrus_prepare:v1"
    ))
  end

  it "creates a direct Job from a currently applicable server-owned job CTA" do
    write_bare_clone(files: { "Gemfile" => "source 'https://rubygems.org'\n" })
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/recommendations/github_actions_ci", as: :json
    }.to change { repository.jobs.where(kind: "direct").count }.by(1)

    expect(response).to have_http_status(:created)
    job = repository.jobs.where(kind: "direct").order(:id).last
    expect(job.issue_title).to eq("Add GitHub Actions CI")
    expect(job.issue_body).to include("CI")
    expect(parse_body["redirect_to"]).to eq("/jobs/#{job.id}")
  end

  it "applies a low-risk repository toggle and returns the updated detail payload" do
    repository.update!(prepare_enabled: false)
    write_bare_clone(files: { "README.md" => "hi\n" })
    sign_in_as(user)

    post "/api/v1/app/repositories/#{repository.id}/recommendations/enable_prepare", as: :json

    expect(response).to have_http_status(:ok)
    expect(repository.reload.prepare_enabled).to be(true)
    expect(parse_body.dig("repository", "id")).to eq(repository.id)
    expect(parse_body["message"]).to eq("Repository setting enabled.")
  end

  it "rejects stale or inapplicable recommendation actions" do
    write_bare_clone(files: { ".github/workflows/ci.yml" => "name: CI\n" })
    sign_in_as(user)

    post "/api/v1/app/repositories/#{repository.id}/recommendations/github_actions_ci", as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
  end
end
