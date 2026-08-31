require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::JobDetailPayload, :ci_only do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  def workflows_payload_for(job)
    described_class.workflows(job: job, user: user)
  end

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def attach_work_unit(workflow, member_jobs:, kind: workflow.trigger_kind, state: "running", blocked_reason: nil)
    primary = member_jobs.first
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary.repository,
      scope_type: primary.epic_id.present? ? "epic" : "job",
      scope_id: primary.epic_id.presence || primary.id,
      actor: primary.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: primary.repository,
      scope_type: intent.scope_type,
      scope_id: intent.scope_id,
      workflow: workflow,
      blocked_reason: blocked_reason,
      blocked_details: blocked_reason ? { "source" => "spec" } : {}
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end
  describe "dependencies" do
    it "serializes epic dependency targets" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocker = Factories.epic(user: user, repository: repo, title: "Pave the road", state: "ready")
      JobDependency.create!(job: job, depends_on_epic: blocker, source: "manual", created_by_user: user)

      dependency = payload_for(job).fetch(:dependencies).sole

      expect(dependency[:succeeded]).to be(false)
      expect(dependency[:depends_on_job]).to be_nil
      expect(dependency[:depends_on_epic]).to include(
        id: blocker.id,
        display_number: blocker.slug,
        title: "Pave the road",
        state: "ready",
        repository_slug: repo.slug,
        epic_path: "/epics/#{blocker.id}"
      )
    end
  end

  describe "#actions_json can_run_visual_review" do
    # Mirrors can_start_preview's approach: read .syrus.yml straight off the
    # local bare clone (no GitHub API call) so job-detail rendering stays
    # cheap. Build a real tiny bare clone under a scratch SYRUS_DATA_ROOT so
    # the git-show code path is exercised rather than stubbed away.
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

      clone_path = @data_root.join("clones", "#{repository.id}.git")
      FileUtils.mkdir_p(clone_path.dirname)
      system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir
    end

    it "is true for an implemented job when .syrus.yml enables visual_review" do
      write_bare_clone(repo, syrus_yml: "visual_review:\n  enabled: true\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(true)
    end

    it "is false when .syrus.yml explicitly disables visual_review" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      write_bare_clone(repo, syrus_yml: "visual_review:\n  enabled: false\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end

    it "falls back to the instance-wide default when .syrus.yml has a visual_review block without an enabled key" do
      write_bare_clone(repo, syrus_yml: "visual_review:\n  rounds: 2\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(true)

      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end

    it "falls back to the instance-wide default when .syrus.yml has no visual_review block" do
      write_bare_clone(repo)
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(true)

      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end

    it "falls back to the instance-wide default when there is no local clone yet" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(true)
    end

    it "is false for a job that is not implemented or approved, even when configured" do
      write_bare_clone(repo, syrus_yml: "visual_review:\n  enabled: true\n")
      job = Factories.job_record(user: user, repository: repo, state: "running")

      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end

    it "is false for an implemented job with an active run" do
      write_bare_clone(repo, syrus_yml: "visual_review:\n  enabled: true\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")
      job.runs.create!(trigger_kind: "manual_visual_review", agent_provider: job.agent_provider)

      expect(payload_for(job).dig(:actions, :can_run_visual_review)).to be(false)
    end
  end

  describe "#actions_json can_request_changes" do
    around do |example|
      setting = AppSetting.current
      original_mode = setting.mode
      setting.update!(mode: "simple", mode_configured_at: Time.current)
      example.run
    ensure
      setting&.update!(mode: original_mode || "advanced")
    end

    it "is true for an implemented job" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(true)
    end

    it "is true for an approved-but-not-yet-landed job" do
      job = Factories.job_record(user: user, repository: repo, state: "approved", approved_at: Time.current)

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(true)
    end

    it "is true for an already-closed/merged job" do
      job = Factories.job_record(user: user, repository: repo, state: "closed", closure_reason: "pr_merged")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(true)
    end

    it "is false for a job still running" do
      job = Factories.job_record(user: user, repository: repo, state: "running")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(false)
    end

    it "is false for a legacy simple-mode Epic child job" do
      epic = Factories.epic(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, state: "implemented", epic: epic)

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(false)
    end

    it "is false for a job closed for an unsuccessful reason" do
      job = Factories.job_record(user: user, repository: repo, state: "closed", closure_reason: "invalidated")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(false)
    end

    it "is false outside simple mode even for an implemented standalone job" do
      AppSetting.current.update!(mode: "advanced")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_request_changes)).to be(false)
    end
  end

  describe "#actions_json can_deploy and #deploy" do
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

      clone_path = @data_root.join("clones", "#{repository.id}.git")
      FileUtils.mkdir_p(clone_path.dirname)
      system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir
    end

    it "is true for an implemented job when .syrus.yml configures deploy" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_deploy)).to be(true)
    end

    it "is false when .syrus.yml has no deploy block" do
      write_bare_clone(repo)
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).dig(:actions, :can_deploy)).to be(false)
    end

    it "is false for a job that has not been implemented yet, even when configured" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")
      job = Factories.job_record(user: user, repository: repo, state: "running")

      expect(payload_for(job).dig(:actions, :can_deploy)).to be(false)
    end

    it "is true for a closed job that landed, when configured" do
      write_bare_clone(repo, syrus_yml: "deploy:\n  run: bin/deploy\n")
      job = Factories.job_record(user: user, repository: repo, state: "closed", landed_sha: "abc123")

      expect(payload_for(job).dig(:actions, :can_deploy)).to be(true)
    end

    it "includes the latest deploy workflow's status" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")
      Workflow.create!(job: job, trigger_kind: "deploy", state: "succeeded", finished_at: 1.hour.ago)
      latest = Workflow.create!(job: job, trigger_kind: "deploy", state: "running", started_at: Time.current)

      deploy = payload_for(job).fetch(:deploy)

      expect(deploy).to include(id: latest.id, state: "running")
    end

    it "is nil when no deploy workflow exists" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")

      expect(payload_for(job).fetch(:deploy)).to be_nil
    end
  end

  describe "#delivery_status" do
    it "exposes the job's derived apparent delivery status" do
      job = Factories.job_record(user: user, repository: repo, state: "approved")

      expect(payload_for(job).dig(:job, :delivery_status)).to eq(:approved_for_local_landing)
    end
  end

  describe "delivery track, PR links, and send_job_upstream" do
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

      clone_path = @data_root.join("clones", "#{repository.id}.git")
      FileUtils.mkdir_p(clone_path.dirname)
      system("git", "clone", "-q", "--bare", work_dir, clone_path.to_s, exception: true)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir
    end

    def upstream_export_syrus_yml
      <<~YAML
        delivery:
          upstream_export:
            enabled: true
          ref_movement_actions:
            send_job_upstream:
              enabled: true
              source: { kind: job_branch }
              target: { kind: upstream_intake }
              mode: manual_pr
      YAML
    end

    it "defaults delivery_track and delivery_target_ref for a repository with no delivery config" do
      job = Factories.job_record(user: user, repository: repo, state: "approved")

      payload = payload_for(job).fetch(:job)

      expect(payload[:delivery_track]).to eq("default")
      expect(payload[:delivery_target_ref]).to eq(repo.default_branch)
    end

    it "exposes pr_links for the job, one entry per role" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented")
      JobPrLink.record!(
        job: job,
        role: JobPrLink::ROLE_LOCAL,
        source_repository_id: repo.id,
        source_ref: "syrus/issue-1",
        target_repository_id: repo.id,
        target_ref: "main",
        pr_number: 42
      )

      pr_links = payload_for(job).fetch(:pr_links)

      expect(pr_links).to contain_exactly(
        include(
          role: "local",
          source_ref: "syrus/issue-1",
          target_ref: "main",
          pr_number: 42,
          pr_url: "https://github.com/#{repo.owner}/#{repo.name}/pull/42"
        )
      )
    end

    it "reports can_send_job_upstream as false with no blocked reason when the repository hasn't configured the action" do
      job = Factories.job_record(user: user, repository: repo, state: "approved")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_send_job_upstream]).to be(false)
      expect(actions[:send_job_upstream_blocked_reason]).to be_nil
    end

    it "reports can_send_job_upstream as true once send_job_upstream is configured and the job is eligible" do
      canonical = Factories.repository(user: user, default_branch: "main")
      fork_repo = Factories.repository(user: user, default_branch: "main", upstream_repository: canonical)
      write_bare_clone(fork_repo, syrus_yml: upstream_export_syrus_yml)
      job = Factories.job_record(user: user, repository: fork_repo, state: "approved", branch_name: "syrus/issue-9")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_send_job_upstream]).to be(true)
      expect(actions[:send_job_upstream_blocked_reason]).to be_nil
    end

    it "surfaces the blocked reason when send_job_upstream is configured but the job isn't eligible" do
      canonical = Factories.repository(user: user, default_branch: "main")
      fork_repo = Factories.repository(user: user, default_branch: "main", upstream_repository: canonical)
      write_bare_clone(fork_repo, syrus_yml: upstream_export_syrus_yml)
      job = Factories.job_record(user: user, repository: fork_repo, state: "approved", branch_name: nil)

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_send_job_upstream]).to be(false)
      expect(actions[:send_job_upstream_blocked_reason]).to include("no branch")
    end
  end
end
