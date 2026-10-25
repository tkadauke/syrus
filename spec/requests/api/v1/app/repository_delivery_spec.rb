require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "App API repository delivery payload", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, default_branch: "main") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(repository, syrus_yml: nil)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, "README.md"), "hi") unless syrus_yml
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml) if syrus_yml
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  describe "GET /api/v1/app/repositories/:id" do
    it "omits the delivery key for a repository with no delivery config" do
      write_bare_clone(repo)

      get "/api/v1/app/repositories/#{repo.id}"

      expect(response).to have_http_status(:ok)
      expect(parse_body["delivery"]).to be_nil
    end

    it "includes the delivery tracks payload for a repository with delivery config" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          tracks:
            default:
              branch: develop
          promotion:
            enabled: true
            mode: manual_pr
      YAML

      get "/api/v1/app/repositories/#{repo.id}"

      expect(response).to have_http_status(:ok)
      delivery = parse_body["delivery"]
      expect(delivery).not_to be_nil
      expect(delivery["tracks"].map { |track| track["name"] }).to contain_exactly("default")
      expect(delivery["tracks"].first["branch"]).to eq("develop")
      expect(delivery["ref_movement_actions"]).to contain_exactly(
        a_hash_including("name" => "promote_development_to_release", "enabled" => true, "available" => true)
      )
      expect(delivery["recent_ref_movement_workflows"]).to eq([])
      expect(delivery["recent_pr_ingestions"]).to eq([])
    end
  end

  describe "POST /api/v1/app/repositories/:id/ref_movement_actions" do
    let(:policy) do
      instance_double(
        DeliveryPolicy,
        promotion_enabled?: true,
        promotion_mode: "manual_pr",
        promotion_grade_phases: [ "promotion" ],
        promotion_source_branch: "develop",
        promotion_target_branch: "main"
      )
    end

    before do
      allow(DeliveryPolicy).to receive(:for).with(repository: repo).and_return(policy)
      allow(StepDispatcher).to receive(:start_workflow)
    end

    it "dispatches promotion for a repository writer" do
      expect {
        post "/api/v1/app/repositories/#{repo.id}/ref_movement_actions",
          params: { action_name: "promote_development_to_release" }, as: :json
      }.to change(RefMovementAction, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include("message" => "Promotion started.", "workflow_id" => Workflow.last.id)
      expect(RefMovementAction.last).to be_dispatched
    end

    it "returns the in-flight blocker to the UI" do
      pending_job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: pending_job, trigger_kind: "promotion", state: "queued")

      post "/api/v1/app/repositories/#{repo.id}/ref_movement_actions",
        params: { action_name: "promote_development_to_release" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("promotion workflow #{workflow.id} is already queued")
      expect(RefMovementAction.last).to be_blocked
    end

    it "forbids a read-only repository member" do
      reader = Factories.user
      RepositoryMembership.create!(repository: repo, user: reader, role: "read")
      sign_in_as(reader)

      post "/api/v1/app/repositories/#{repo.id}/ref_movement_actions",
        params: { action_name: "promote_development_to_release" }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(RefMovementAction.count).to eq(0)
    end
  end
end
