require "rails_helper"

RSpec.describe App::PreviewProjects do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) { Factories.job_record(repository: repository, user: user, branch_name: "feature", state: "implemented") }
  let(:client) { instance_double(GithubClient) }

  # The default-branch TargetGraph and the Job branch diff are both read
  # through the GitHub API (GithubClient) rather than the repository's local
  # bare clone (`RepositoryBareClone`): PreviewProjects is read from web-tier
  # request paths (JobPreviewController, TargetGraphsController), and web
  # pods don't mount the worker's on-disk bare clone (see "Deploy target" in
  # CLAUDE.md — "Web pods don't need this volume"). No $SYRUS_DATA_ROOT
  # clone is created anywhere in this spec, simulating that environment; the
  # `client:` seam injects a double directly instead of stubbing
  # `GithubClient.for`, since `instance_double` isn't `is_a?(GithubClient)`.
  def described(job)
    described_class.new(job, client: client)
  end

  def stub_tree(paths)
    allow(client).to receive(:file_tree_at)
      .with(repository.slug, repository.default_branch)
      .and_return(items: paths.map { |path| { path: path, size: 0 } }, truncated: false)
  end

  def stub_syrus_yml(path, content)
    allow(client).to receive(:file_content_at)
      .with(repository.slug, path, repository.default_branch)
      .and_return(content: content, size: content.bytesize)
  end

  def stub_changed_files(paths)
    allow(client).to receive(:compare_files)
      .with(repository.slug, job.effective_base_branch, job.branch_name)
      .and_return(
        files: paths.map { |path| { path: path, status: "modified", additions: 1, deletions: 1, patch: nil } },
        truncated: false
      )
  end

  it "returns the one affected nested preview project" do
    stub_tree(%w[apps/web/.syrus.yml apps/api/.syrus.yml apps/web/index.tsx])
    stub_syrus_yml("apps/web/.syrus.yml", "project:\n  id: web\n  label: Web\npreview:\n  start: npm run dev\n")
    stub_syrus_yml("apps/api/.syrus.yml", "project:\n  id: api\n  label: API\npreview:\n  start: bin/server\n")
    stub_changed_files(%w[apps/web/index.tsx])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to eq([ "web" ])
    expect(result.unavailable_reason).to be_nil
  end

  it "returns multiple affected preview projects when the diff spans them" do
    stub_tree(%w[apps/web/.syrus.yml apps/admin/.syrus.yml apps/web/index.tsx apps/admin/index.tsx])
    stub_syrus_yml("apps/web/.syrus.yml", "project:\n  id: web\n  label: Web\npreview:\n  start: npm run dev\n")
    stub_syrus_yml("apps/admin/.syrus.yml", "project:\n  id: admin\n  label: Admin\npreview:\n  start: npm run dev\n")
    stub_changed_files(%w[apps/web/index.tsx apps/admin/index.tsx])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to match_array(%w[web admin])
  end

  it "reports when no affected project has a preview" do
    stub_tree(%w[apps/web/.syrus.yml docs/readme.md])
    stub_syrus_yml("apps/web/.syrus.yml", "project:\n  id: web\npreview:\n  start: npm run dev\n")
    stub_changed_files(%w[docs/readme.md])

    result = described(job).for_job

    expect(result.choices).to eq([])
    expect(result.unavailable_reason).to eq("no_affected_preview_project")
  end

  it "preserves legacy root preview behavior" do
    stub_tree([ ".syrus.yml", "app/models/user.rb" ])
    stub_syrus_yml(".syrus.yml", "preview:\n  start: bin/dev\n")
    stub_changed_files(%w[app/models/user.rb])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to eq([ "repo" ])
    expect(result.choices.first.label).to eq("Repository")
  end

  it "does not include the root preview for files owned by a nested preview project" do
    stub_tree([ ".syrus.yml", "desktop/.syrus.yml", "desktop/src/App.tsx" ])
    stub_syrus_yml(".syrus.yml", "preview:\n  start: bin/dev\n")
    stub_syrus_yml("desktop/.syrus.yml", "project:\n  id: desktop\n  label: Desktop App\npreview:\n  start: npm run dev\n")
    stub_changed_files(%w[desktop/src/App.tsx])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to eq([ "desktop" ])
  end

  it "includes root and nested previews when a diff touches both ownership scopes" do
    stub_tree([ ".syrus.yml", "desktop/.syrus.yml", "app/models/job.rb", "desktop/src/App.tsx" ])
    stub_syrus_yml(".syrus.yml", "preview:\n  start: bin/dev\n")
    stub_syrus_yml("desktop/.syrus.yml", "project:\n  id: desktop\npreview:\n  start: npm run dev\n")
    stub_changed_files(%w[app/models/job.rb desktop/src/App.tsx])

    result = described(job).for_job

    expect(result.choices.map(&:id)).to match_array(%w[repo desktop])
  end

  it "falls back to legacy root behavior when GitHub credentials are unavailable" do
    unauthenticated_user = Factories.user
    unauthenticated_repository = Factories.repository(user: unauthenticated_user, default_branch: "main")
    unauthenticated_job = Factories.job_record(repository: unauthenticated_repository, user: unauthenticated_user, branch_name: "feature", state: "implemented")
    allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(true)

    result = described_class.for_job(unauthenticated_job)

    expect(result.choices.map(&:id)).to eq([ "repo" ])
  end
end
