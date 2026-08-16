require "rails_helper"
require "open3"

RSpec.describe PreviewWorkspace do
  class PreviewWorkspaceSpecGit
    def initialize(source_path)
      @source_path = source_path
    end

    def run(*args, env: nil, chdir: nil)
      case args.first
      when "clone"
        destination = args.last
        FileUtils.mkdir_p(destination)
        FileUtils.cp_r(Dir.glob(File.join(@source_path, "*"), File::FNM_DOTMATCH).reject { |path| path.end_with?("/.", "/..") }, destination)
      end
    end

    def configure_author(*) = true
  end

  around do |example|
    Dir.mktmpdir do |data_root|
      original = ENV["SYRUS_DATA_ROOT"]
      ENV["SYRUS_DATA_ROOT"] = data_root
      example.run
    ensure
      ENV["SYRUS_DATA_ROOT"] = original
    end
  end

  it "patches vite-ruby skipProxy in the disposable preview checkout" do
    source_path = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(source_path, "config"))
    File.write(
      File.join(source_path, "config", "vite.json"),
      JSON.generate("all" => { "skipProxy" => true }, "development" => { "skipProxy" => true })
    )

    repository = Factories.repository
    job = Factories.job_record(repository: repository, branch_name: "preview-branch", state: "implemented")
    preview_environment = PreviewEnvironment.create!(job: job, state: "starting")
    allow_any_instance_of(Repository).to receive(:authenticated_url).and_return(source_path)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("https://github.example/acme/app.git")

    described_class.prepare!(preview_environment, git: PreviewWorkspaceSpecGit.new(source_path))

    patched = JSON.parse(File.read(File.join(preview_environment.reload.workspace_path, "config", "vite.json")))
    original = JSON.parse(File.read(File.join(source_path, "config", "vite.json")))
    expect(patched.dig("all", "skipProxy")).to be(false)
    expect(patched.dig("development", "skipProxy")).to be(false)
    expect(original.dig("all", "skipProxy")).to be(true)
  ensure
    FileUtils.rm_rf(source_path) if source_path
  end

  describe ".cleanup_for" do
    it "removes the workspace directory and nulls the stale workspace_path column" do
      repository = Factories.repository
      job = Factories.job_record(repository: repository, branch_name: "preview-branch", state: "implemented")
      workspace_path = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(workspace_path, "log"))
      preview_environment = PreviewEnvironment.create!(job: job, state: "stopping", workspace_path: workspace_path)

      described_class.cleanup_for(preview_environment)

      expect(Dir.exist?(workspace_path)).to be(false)
      expect(preview_environment.reload.workspace_path).to be_nil
    end
  end

  describe "revision selection" do
    # Real git repo (not the file-copying stub above) so merge-base
    # resolution is exercised against genuine history instead of a fake.
    def init_source_repo
      source_path = Dir.mktmpdir
      run_git(source_path, "init", "--quiet", "--initial-branch=main")
      run_git(source_path, "config", "user.email", "bot@example.com")
      run_git(source_path, "config", "user.name", "Bot")
      write_commit(source_path, "README.md", "initial")
      source_path
    end

    def write_commit(source_path, filename, content)
      File.write(File.join(source_path, filename), content)
      run_git(source_path, "add", filename)
      run_git(source_path, "commit", "--quiet", "-m", content)
      head_sha(source_path)
    end

    def branch_from(source_path, branch, from:)
      run_git(source_path, "checkout", "--quiet", "-b", branch, from)
    end

    def head_sha(path)
      run_git(path, "rev-parse", "HEAD").strip
    end

    def run_git(chdir, *args)
      output = +""
      status = nil
      Open3.popen2e(*[ "git", *args ], chdir: chdir) do |_stdin, stdout_err, wait_thr|
        output = stdout_err.read
        status = wait_thr.value
      end
      raise "git #{args.join(' ')} failed: #{output}" unless status.success?

      output
    end

    def stub_repository!(repository, source_path)
      allow_any_instance_of(Repository).to receive(:authenticated_url).and_return(source_path)
      allow_any_instance_of(Repository).to receive(:remote_url).and_return("https://github.example/acme/app.git")
    end

    it "defaults to checking out the Job's feature branch" do
      source_path = init_source_repo
      branch_from(source_path, "feature", from: "main")
      feature_sha = write_commit(source_path, "feature.txt", "feature work")

      repository = Factories.repository(default_branch: "main")
      job = Factories.job_record(repository: repository, branch_name: "feature", state: "implemented")
      preview_environment = PreviewEnvironment.create!(job: job, state: "starting")
      stub_repository!(repository, source_path)

      described_class.prepare!(preview_environment, git: GitRunner.new)

      expect(head_sha(preview_environment.reload.workspace_path)).to eq(feature_sha)
    ensure
      FileUtils.rm_rf(source_path) if source_path
    end

    it "checks out the Job's base revision when revision: :base is given" do
      source_path = init_source_repo
      base_sha = head_sha(source_path)
      branch_from(source_path, "feature", from: "main")
      write_commit(source_path, "feature.txt", "feature work")

      repository = Factories.repository(default_branch: "main")
      job = Factories.job_record(repository: repository, branch_name: "feature", state: "implemented")
      preview_environment = PreviewEnvironment.create!(job: job, state: "starting")
      stub_repository!(repository, source_path)

      described_class.prepare!(preview_environment, git: GitRunner.new, revision: :base)

      expect(head_sha(preview_environment.reload.workspace_path)).to eq(base_sha)
    ensure
      FileUtils.rm_rf(source_path) if source_path
    end

    it "resolves the base revision against the stacked parent branch, not the repo default" do
      source_path = init_source_repo
      branch_from(source_path, "parent-branch", from: "main")
      parent_sha = write_commit(source_path, "parent.txt", "parent work")
      branch_from(source_path, "child-branch", from: "parent-branch")
      write_commit(source_path, "child.txt", "child work")

      repository = Factories.repository(default_branch: "main")
      parent_job = Factories.job_record(
        repository: repository, branch_name: "parent-branch", pr_number: 10, state: "implemented"
      )
      child_job = Factories.job_record(
        repository: repository, branch_name: "child-branch", parent_job: parent_job, state: "implemented"
      )
      preview_environment = PreviewEnvironment.create!(job: child_job, state: "starting")
      stub_repository!(repository, source_path)

      expect(child_job.effective_base_branch).to eq("parent-branch")

      described_class.prepare!(preview_environment, git: GitRunner.new, revision: :base)

      expect(head_sha(preview_environment.reload.workspace_path)).to eq(parent_sha)
    ensure
      FileUtils.rm_rf(source_path) if source_path
    end
  end
end
