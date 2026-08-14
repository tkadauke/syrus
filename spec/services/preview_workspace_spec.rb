require "rails_helper"

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
end
