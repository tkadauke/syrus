require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Mcp::Tools delivery-track tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def chat_context = { chat_session: chat_session }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(repo, syrus_yml:)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml)
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = RepositoryBareClone.path_for(repo)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  describe Mcp::Tools::ListDeliveryTracksTool do
    it "lists the default track resolved to the repository default branch when no delivery: is configured" do
      response = described_class.call(server_context: chat_context)

      expect(response).not_to be_error
      tracks = payload(response)[:tracks]
      expect(tracks).to contain_exactly(a_hash_including(name: "default", default: true, branch: "main"))
    end

    it "lists every configured track" do
      write_bare_clone(repository, syrus_yml: <<~YAML)
        delivery:
          tracks:
            default:
              branch: develop
            hotfix:
              branch: main
      YAML

      tracks = payload(described_class.call(server_context: chat_context))[:tracks]
      expect(tracks.map { |t| t[:name] }).to contain_exactly("default", "hotfix")
    end
  end

  describe Mcp::Tools::ResolveDeliveryPolicyTool do
    it "resolves repository-level policy with no job_id" do
      response = described_class.call(server_context: chat_context)

      expect(response).not_to be_error
      body = payload(response)
      expect(body[:delivery_track]).to eq("default")
      expect(body[:job_landing_branch]).to eq("main")
      expect(body[:promotion][:enabled]).to be(false)
    end

    it "rejects a job_id belonging to a different repository" do
      other_repo = Factories.repository(user: user)
      other_job = Factories.job_record(user: user, repository: other_repo)

      response = described_class.call(job_id: other_job.id, server_context: chat_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("different repository")
    end

    it "returns an error for an unknown job_id" do
      response = described_class.call(job_id: 0, server_context: chat_context)

      expect(response).to be_error
    end
  end

  describe Mcp::Tools::SelectJobDeliveryTrackTool do
    it "updates delivery_track on an open, unapproved job" do
      job = Factories.job_record(user: user, repository: repository, state: "queued")

      response = described_class.call(job_id: job.id, track: "hotfix", server_context: chat_context)

      expect(response).not_to be_error
      expect(job.reload.delivery_track).to eq("hotfix")
    end

    it "clears delivery_track when track is blank" do
      job = Factories.job_record(user: user, repository: repository, state: "queued", delivery_track: "hotfix")

      described_class.call(job_id: job.id, track: "", server_context: chat_context)

      expect(job.reload.delivery_track).to be_nil
    end

    it "rejects a job that is already approved" do
      job = Factories.job_record(user: user, repository: repository, state: "approved")

      response = described_class.call(job_id: job.id, track: "hotfix", server_context: chat_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("already been approved")
    end

    it "rejects a closed job" do
      job = Factories.job_record(user: user, repository: repository, state: "closed", closure_reason: "pr_merged")

      response = described_class.call(job_id: job.id, track: "hotfix", server_context: chat_context)

      expect(response).to be_error
    end
  end
end
