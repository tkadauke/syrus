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
      expect(delivery["ref_movement_actions"]).to eq([])
      expect(delivery["recent_ref_movement_workflows"]).to eq([])
      expect(delivery["recent_pr_ingestions"]).to eq([])
    end
  end
end
