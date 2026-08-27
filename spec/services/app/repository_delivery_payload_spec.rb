require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::RepositoryDeliveryPayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }

  around do |example|
    @data_root = Pathname.new(Dir.mktmpdir("syrus-data"))
    previous_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = @data_root.to_s
    example.run
    ENV["SYRUS_DATA_ROOT"] = previous_root
    FileUtils.rm_rf(@data_root)
  end

  def write_bare_clone(repository, syrus_yml:)
    work_dir = Dir.mktmpdir("syrus-work")
    system("git", "init", "-q", "-b", "main", work_dir, exception: true)
    system("git", "-C", work_dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", work_dir, "config", "user.name", "Test", exception: true)
    File.write(File.join(work_dir, ".syrus.yml"), syrus_yml)
    system("git", "-C", work_dir, "add", ".", exception: true)
    system("git", "-C", work_dir, "commit", "-q", "-m", "init", exception: true)

    clone_path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(clone_path.dirname)
    system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  describe "with no delivery config" do
    it "reports one default track with no queue link, and empty history sections" do
      Factories.job_record(repository: repository, state: "approved")

      payload = described_class.call(repository: repository)

      expect(payload[:tracks]).to contain_exactly(
        include(name: "default", default: true, branch: "main", landing_queue_count: 1, queue_path: nil)
      )
      expect(payload[:promotion]).to include(enabled: false)
      expect(payload[:hotfix_sync]).to include(enabled: false)
      expect(payload[:upstream_export]).to include(enabled: false)
      expect(payload[:ref_movement_actions]).to eq([])
      expect(payload[:recent_ref_movement_actions]).to eq([])
      expect(payload[:recent_workflows]).to eq([])
      expect(payload[:recent_pr_ingestions]).to eq([])
      expect(payload[:paths][:app_dispatch_ref_movement_action_repository_path])
        .to eq("/api/v1/app/repositories/#{repository.id}/dispatch_ref_movement_action")
    end
  end

  describe "with tracks, promotion, and a ref_movement_actions block configured" do
    before do
      write_bare_clone(repository, syrus_yml: <<~YAML)
        delivery:
          tracks:
            default:
              branch: develop
            hotfix:
              branch: main
          promotion:
            enabled: true
            mode: manual_pr
          ref_movement_actions:
            submit_branch_upstream:
              enabled: true
              source: { kind: branch }
              target: { kind: upstream_intake }
              mode: manual_pr
      YAML
    end

    it "exposes both tracks with a queue link, promotion settings, and configured ref-movement actions" do
      payload = described_class.call(repository: repository)

      expect(payload[:tracks]).to contain_exactly(
        include(name: "default", branch: "develop", queue_path: a_string_matching(%r{\A/dashboard/jobs\?q=})),
        include(name: "hotfix", branch: "main", queue_path: a_string_matching(%r{\A/dashboard/jobs\?q=}))
      )
      expect(payload[:promotion]).to include(enabled: true, mode: "manual_pr", source_branch: "develop", target_branch: "main")
      expect(payload[:ref_movement_actions]).to contain_exactly(
        include(name: "submit_branch_upstream", enabled: true, available: false, blocked_reason: "repository has no in-instance upstream_repository")
      )
    end
  end

  describe "recent_ref_movement_actions" do
    it "includes dispatched and blocked audit rows, most recent first" do
      older = RefMovementAction.create!(
        repository: repository, requested_by_user: user, action_name: "submit_branch_upstream",
        state: "blocked", blocked_reason: "not configured in delivery.ref_movement_actions", created_at: 1.hour.ago
      )
      newer = RefMovementAction.create!(
        repository: repository, requested_by_user: user, action_name: "send_job_upstream",
        state: "blocked", blocked_reason: "job is required for send_job_upstream", created_at: Time.current
      )

      payload = described_class.call(repository: repository)

      expect(payload[:recent_ref_movement_actions].map { |row| row[:id] }).to eq([ newer.id, older.id ])
      expect(payload[:recent_ref_movement_actions].first).to include(
        action_name: "send_job_upstream", state: "blocked", blocked_reason: "job is required for send_job_upstream"
      )
    end
  end

  describe "recent_workflows" do
    it "resolves source/target refs from the anchor job's matching JobPrLink" do
      job = Factories.job_record(repository: repository, kind: "direct", issue_number: nil, branch_name: "develop")
      workflow = Workflow.create!(job: job, trigger_kind: "promotion", state: "succeeded", finished_at: Time.current)
      JobPrLink.create!(job: job, role: JobPrLink::ROLE_PROMOTION, source_ref: "develop", target_ref: "main")

      payload = described_class.call(repository: repository)

      expect(payload[:recent_workflows]).to contain_exactly(
        include(id: workflow.id, trigger_kind: "promotion", state: "succeeded", source_ref: "develop", target_ref: "main")
      )
      expect(payload[:tracks].first[:last_promotion_or_sync_at]).to eq(workflow.finished_at.iso8601)
    end
  end

  describe "recent_pr_ingestions" do
    def external_pr_job(pr_number)
      Job.create!(
        user: user, repository: repository, kind: "external_pr", state: "implemented",
        external_pr_number: pr_number, issue_title: "Imported PR #{pr_number}"
      )
    end

    it "reads the classification from the external_ingest JobPrLink's metadata" do
      job = external_pr_job(55)
      JobPrLink.create!(
        job: job, role: JobPrLink::ROLE_EXTERNAL_INGEST, pr_number: 55,
        metadata: { "provenance" => "syrus_job_export", "ingest_mode" => "imported", "source_repo_slug" => "fork/widgets" }
      )

      payload = described_class.call(repository: repository)

      expect(payload[:recent_pr_ingestions]).to contain_exactly(
        include(pr_number: 55, provenance: "syrus_job_export", ingest_mode: "imported", source_repo_slug: "fork/widgets")
      )
    end

    it "defaults an un-classified ingested PR to external_unknown" do
      external_pr_job(56)

      payload = described_class.call(repository: repository)

      expect(payload[:recent_pr_ingestions]).to contain_exactly(include(pr_number: 56, provenance: "external_unknown"))
    end
  end
end
