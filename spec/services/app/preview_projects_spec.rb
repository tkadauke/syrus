require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::PreviewProjects do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) { Factories.job_record(repository: repository, user: user, branch_name: "feature", state: "implemented") }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-preview-projects-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(files:, changed_files:)
    work_dir = Dir.mktmpdir("syrus-preview-projects-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    files.each do |path, content|
      full_path = File.join(work_dir, path)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, content)
    end
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "main", exception: true)
    system("git", "-C", work_dir, "checkout", "-q", "-b", "feature", exception: true)
    changed_files.each do |path, content|
      full_path = File.join(work_dir, path)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, content)
    end
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "feature", exception: true)

    clone_path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  it "returns the one affected nested preview project" do
    write_bare_clone(
      files: {
        "apps/web/.syrus.yml" => "project:\n  id: web\n  label: Web\npreview:\n  start: npm run dev\n",
        "apps/api/.syrus.yml" => "project:\n  id: api\n  label: API\npreview:\n  start: bin/server\n",
        "apps/web/index.tsx" => "old"
      },
      changed_files: { "apps/web/index.tsx" => "new" }
    )

    result = described_class.for_job(job)

    expect(result.choices.map(&:id)).to eq([ "web" ])
    expect(result.unavailable_reason).to be_nil
  end

  it "returns multiple affected preview projects when the diff spans them" do
    write_bare_clone(
      files: {
        "apps/web/.syrus.yml" => "project:\n  id: web\n  label: Web\npreview:\n  start: npm run dev\n",
        "apps/admin/.syrus.yml" => "project:\n  id: admin\n  label: Admin\npreview:\n  start: npm run dev\n",
        "apps/web/index.tsx" => "old",
        "apps/admin/index.tsx" => "old"
      },
      changed_files: {
        "apps/web/index.tsx" => "new",
        "apps/admin/index.tsx" => "new"
      }
    )

    result = described_class.for_job(job)

    expect(result.choices.map(&:id)).to match_array(%w[web admin])
  end

  it "reports when no affected project has a preview" do
    write_bare_clone(
      files: {
        "apps/web/.syrus.yml" => "project:\n  id: web\npreview:\n  start: npm run dev\n",
        "docs/readme.md" => "old"
      },
      changed_files: { "docs/readme.md" => "new" }
    )

    result = described_class.for_job(job)

    expect(result.choices).to eq([])
    expect(result.unavailable_reason).to eq("no_affected_preview_project")
  end

  it "preserves legacy root preview behavior" do
    write_bare_clone(
      files: {
        ".syrus.yml" => "preview:\n  start: bin/dev\n",
        "app/models/user.rb" => "old"
      },
      changed_files: { "app/models/user.rb" => "new" }
    )

    result = described_class.for_job(job)

    expect(result.choices.map(&:id)).to eq([ "repo" ])
    expect(result.choices.first.label).to eq("Repository")
  end
end
