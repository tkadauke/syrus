require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe DeliveryPolicy do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, default_branch: "main") }

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

  describe "against a bare repository (no bare clone, no .syrus.yml)" do
    subject(:policy) { described_class.for(repository: repo) }

    it "resolves the job landing branch to the repository default branch" do
      expect(policy.job_landing_branch).to eq("main")
    end

    it "resolves the job delivery track to 'default'" do
      expect(policy.job_delivery_track).to eq("default")
    end

    it "resolves review/landing grade phases to review/landing" do
      expect(policy.review_grade_phase).to eq("review")
      expect(policy.landing_grade_phase).to eq("landing")
    end

    it "resolves branch health grade phase to ci" do
      expect(policy.branch_health_grade_phase("main")).to eq("ci")
    end

    it "reports promotion, hotfix sync, and upstream export as disabled" do
      expect(policy.promotion_enabled?).to be(false)
      expect(policy.hotfix_sync_enabled?).to be(false)
      expect(policy.upstream_export_enabled?).to be(false)
    end

    it "reports the default promotion/hotfix sync modes even when disabled" do
      expect(policy.promotion_mode).to eq("auto_pr")
      expect(policy.hotfix_sync_mode).to eq("auto")
    end

    it "reports upstream_export_mode as 'none' when upstream export is disabled" do
      expect(policy.upstream_export_mode).to eq("none")
    end

    it "reports export_upstream_after_local_approval? as false when upstream export is disabled" do
      expect(policy.export_upstream_after_local_approval?).to be(false)
    end

    it "resolves upstream_export_target_branch to nil when the repository has no upstream_repository" do
      expect(policy.upstream_export_target_branch).to be_nil
    end
  end

  describe "against a repository with no delivery: section configured" do
    subject(:policy) { described_class.for(repository: repo) }

    before { write_bare_clone(repo) }

    it "behaves exactly like a bare repository" do
      expect(policy.job_landing_branch).to eq("main")
      expect(policy.job_delivery_track).to eq("default")
      expect(policy.review_grade_phase).to eq("review")
      expect(policy.landing_grade_phase).to eq("landing")
      expect(policy.branch_health_grade_phase("main")).to eq("ci")
      expect(policy.promotion_enabled?).to be(false)
      expect(policy.hotfix_sync_enabled?).to be(false)
      expect(policy.upstream_export_enabled?).to be(false)
    end
  end

  describe "against a repository with a delivery: block configured" do
    subject(:policy) { described_class.for(repository: repo) }

    before do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          tracks:
            default:
              branch: develop
              grade_phases:
                review: review_minimal
                landing: landing_minimal
            hotfix:
              branch: main
              grade_phases:
                review: review_minimal
                landing: promotion

          promotion:
            enabled: true
            mode: manual_pr
            approval_required: true

          hotfix_sync:
            enabled: true
            mode: auto_pr

          upstream_export:
            enabled: true
            mode: branch_pr
      YAML
    end

    it "resolves the job landing branch to the default track's configured branch" do
      expect(policy.job_landing_branch).to eq("develop")
    end

    it "resolves the job delivery track to 'default' (no Job#delivery_track column yet)" do
      expect(policy.job_delivery_track).to eq("default")
    end

    it "resolves review/landing grade phases from the default track" do
      expect(policy.review_grade_phase).to eq("review_minimal")
      expect(policy.landing_grade_phase).to eq("landing_minimal")
    end

    it "resolves branch health grade phase by matching the track's configured branch" do
      expect(policy.branch_health_grade_phase("develop")).to eq("ci")
      expect(policy.branch_health_grade_phase("main")).to eq("ci")
    end

    it "falls back to the default track when no track matches the given branch" do
      expect(policy.branch_health_grade_phase("some-other-branch")).to eq(policy.branch_health_grade_phase("develop"))
    end

    it "reports promotion, hotfix sync, and upstream export as enabled with their configured modes" do
      expect(policy.promotion_enabled?).to be(true)
      expect(policy.promotion_mode).to eq("manual_pr")
      expect(policy.hotfix_sync_enabled?).to be(true)
      expect(policy.hotfix_sync_mode).to eq("auto_pr")
      expect(policy.upstream_export_enabled?).to be(true)
      expect(policy.upstream_export_mode).to eq("branch_pr")
    end

    it "resolves promotion source/target branches from the default track and the repository default branch" do
      expect(policy.promotion_source_branch).to eq("develop")
      expect(policy.promotion_target_branch).to eq("main")
    end

    it "resolves promotion_repair_skill to nil when not configured" do
      expect(policy.promotion_repair_skill).to be_nil
    end

    it "resolves hotfix sync source/target branches as the mirror image of promotion" do
      expect(policy.hotfix_sync_source_branch).to eq("main")
      expect(policy.hotfix_sync_target_branch).to eq("develop")
    end

    it "resolves hotfix_sync_repair_skill to nil when not configured" do
      expect(policy.hotfix_sync_repair_skill).to be_nil
    end
  end

  describe "#promotion_repair_skill" do
    subject(:policy) { described_class.for(repository: repo) }

    it "resolves the configured delivery.promotion.repair_skill" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          promotion:
            enabled: true
            repair_skill: integrate_release_branch
      YAML

      expect(policy.promotion_repair_skill).to eq("integrate_release_branch")
    end
  end

  describe "#hotfix_sync_repair_skill" do
    subject(:policy) { described_class.for(repository: repo) }

    it "resolves the configured delivery.hotfix_sync.repair_skill" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          hotfix_sync:
            enabled: true
            repair_skill: backport_release_hotfix
      YAML

      expect(policy.hotfix_sync_repair_skill).to eq("backport_release_hotfix")
    end
  end

  describe "#export_upstream_after_local_approval?" do
    subject(:policy) { described_class.for(repository: repo) }

    it "defaults to true once upstream export is enabled" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          upstream_export:
            enabled: true
      YAML

      expect(policy.export_upstream_after_local_approval?).to be(true)
    end

    it "respects an explicit after_local_approval: false" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          upstream_export:
            enabled: true
            after_local_approval: false
      YAML

      expect(policy.export_upstream_after_local_approval?).to be(false)
    end

    it "is false when upstream export is not enabled, even if after_local_approval is set" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          upstream_export:
            after_local_approval: true
      YAML

      expect(policy.export_upstream_after_local_approval?).to be(false)
    end
  end

  describe "#upstream_export_target_branch" do
    let(:canonical) { Factories.repository(user: user, default_branch: "main") }

    subject(:policy) { described_class.for(repository: repo) }

    before { repo.update!(upstream_repository: canonical) }

    context "when the repository has no in-instance canonical repository" do
      it "resolves to nil" do
        repo.update!(upstream_repository: nil)
        expect(policy.upstream_export_target_branch).to be_nil
      end
    end

    context "when canonical has a configured development track (canonical-has-dev-track)" do
      before do
        write_bare_clone(canonical, syrus_yml: <<~YAML)
          delivery:
            tracks:
              default:
                branch: develop
        YAML
      end

      it "resolves to canonical's configured development branch" do
        expect(policy.upstream_export_target_branch).to eq("develop")
      end
    end

    context "when canonical uses strict main with no delivery: block (canonical-strict-main)" do
      before { write_bare_clone(canonical) }

      it "resolves to canonical's default branch" do
        expect(policy.upstream_export_target_branch).to eq("main")
      end
    end
  end

  describe "#promotion_source_branch and #promotion_target_branch against a bare repository" do
    subject(:policy) { described_class.for(repository: repo) }

    it "falls back to the repository default branch for both when no delivery: block is configured" do
      expect(policy.promotion_source_branch).to eq("main")
      expect(policy.promotion_target_branch).to eq("main")
    end
  end

  describe "#hotfix_sync_source_branch and #hotfix_sync_target_branch against a bare repository" do
    subject(:policy) { described_class.for(repository: repo) }

    it "falls back to the repository default branch for both when no delivery: block is configured" do
      expect(policy.hotfix_sync_source_branch).to eq("main")
      expect(policy.hotfix_sync_target_branch).to eq("main")
    end
  end

  describe "against a repository whose .syrus.yml fails to parse" do
    subject(:policy) { described_class.for(repository: repo) }

    before { write_bare_clone(repo, syrus_yml: "delivery:\n  promotion:\n    mode: whenever\n") }

    it "falls back to the backward-compatible default instead of raising" do
      expect(policy.job_landing_branch).to eq("main")
      expect(policy.promotion_enabled?).to be(false)
    end
  end

  describe "job argument handling" do
    it "accepts a job constructed via .for and via the per-call override" do
      job = Factories.job(repository: repo)

      via_for = described_class.for(repository: repo, job: job)
      expect(via_for.job_delivery_track).to eq("default")

      via_call = described_class.for(repository: repo)
      expect(via_call.job_delivery_track(job)).to eq("default")
    end
  end

  describe "Job#delivery_track selection" do
    subject(:policy) { described_class.for(repository: repo) }

    before do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          tracks:
            default:
              branch: develop
              grade_phases:
                review: review_minimal
                landing: landing_minimal
            hotfix:
              branch: main
              grade_phases:
                review: review_minimal
                landing: promotion
      YAML
    end

    it "resolves the landing branch and delivery track from Job#delivery_track when it names a configured track" do
      job = Factories.job(repository: repo, delivery_track: "hotfix")

      expect(policy.job_delivery_track(job)).to eq("hotfix")
      expect(policy.job_landing_branch(job)).to eq("main")
      expect(policy.review_grade_phase(job)).to eq("review_minimal")
      expect(policy.landing_grade_phase(job)).to eq("promotion")
    end

    it "falls back to the default track when Job#delivery_track is blank" do
      job = Factories.job(repository: repo, delivery_track: nil)

      expect(policy.job_delivery_track(job)).to eq("default")
      expect(policy.job_landing_branch(job)).to eq("develop")
    end

    it "falls back to the default track when Job#delivery_track names a track the repository hasn't configured" do
      job = Factories.job(repository: repo, delivery_track: "nonexistent")

      expect(policy.job_delivery_track(job)).to eq("default")
      expect(policy.job_landing_branch(job)).to eq("develop")
    end
  end

  describe "#approval_configured?" do
    subject(:policy) { described_class.for(repository: repo) }

    it "is false when there is no bare clone at all" do
      expect(policy.approval_configured?).to be(false)
    end

    it "is false when .syrus.yml has no approval: block" do
      write_bare_clone(repo)

      expect(policy.approval_configured?).to be(false)
    end

    it "is true once an approval: block is present" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        approval:
          job:
            required:
              owner: true
      YAML

      expect(policy.approval_configured?).to be(true)
    end
  end

  describe "#job_approval_satisfied? (Story 7: owner + peer approval)" do
    let(:owner) { user }
    let(:peer) { Factories.user }
    let(:job) { Factories.job(repository: repo, owner_user: owner) }

    def approve!(approver)
      JobApproval.create!(job: job, user: approver, approved_at: Time.current)
    end

    context "when no approval: block is configured" do
      subject(:policy) { described_class.for(repository: repo) }

      before { write_bare_clone(repo) }

      it "falls back to the repository's existing review_policy (self: owner approval only)" do
        expect(repo.review_policy).to eq("self")
        expect(policy.job_approval_satisfied?(job)).to be(false)

        approve!(owner)

        expect(policy.job_approval_satisfied?(job)).to be(true)
      end
    end

    context "when approval.job.required.owner and peer_count are configured" do
      subject(:policy) { described_class.for(repository: repo) }

      before do
        write_bare_clone(repo, syrus_yml: <<~YAML)
          approval:
            job:
              required:
                owner: true
                peer_count: 1
        YAML
      end

      it "is not satisfied by the owner alone" do
        approve!(owner)

        expect(policy.job_approval_satisfied?(job)).to be(false)
      end

      it "does not count a peer approval from someone without repository access" do
        approve!(owner)
        approve!(peer)

        expect(policy.job_approval_satisfied?(job)).to be(false)
      end

      it "is satisfied once a peer with repository access also approves" do
        approve!(owner)
        approve!(peer)
        RepositoryMembership.create!(repository: repo, user: peer, role: "write")

        expect(policy.job_approval_satisfied?(job)).to be(true)
      end

      it "is not satisfied by a peer approval alone when owner approval is required" do
        approve!(peer)
        RepositoryMembership.create!(repository: repo, user: peer, role: "write")

        expect(policy.job_approval_satisfied?(job)).to be(false)
      end
    end

    context "when approval.job.required has no peer_count (defaults to 0)" do
      subject(:policy) { described_class.for(repository: repo) }

      before do
        write_bare_clone(repo, syrus_yml: <<~YAML)
          approval:
            job:
              required:
                owner: true
        YAML
      end

      it "is satisfied by owner approval alone" do
        approve!(owner)

        expect(policy.job_approval_satisfied?(job)).to be(true)
      end
    end
  end

  describe "#requires_operator_approval_for_promotion?" do
    subject(:policy) { described_class.for(repository: repo) }

    it "falls back to delivery.promotion.approval_required when approval.promotion is absent" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          promotion:
            approval_required: true
      YAML

      expect(policy.requires_operator_approval_for_promotion?).to be(true)
    end

    it "defaults to false when neither approval.promotion nor delivery.promotion.approval_required is set" do
      write_bare_clone(repo)

      expect(policy.requires_operator_approval_for_promotion?).to be(false)
    end

    it "is true when approval.promotion.required.maintainer_count is positive" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        approval:
          promotion:
            required:
              maintainer_count: 1
      YAML

      expect(policy.requires_operator_approval_for_promotion?).to be(true)
    end

    it "is false when approval.promotion.required.maintainer_count is 0, even if delivery.promotion.approval_required is true" do
      write_bare_clone(repo, syrus_yml: <<~YAML)
        delivery:
          promotion:
            approval_required: true

        approval:
          promotion:
            required:
              maintainer_count: 0
      YAML

      expect(policy.requires_operator_approval_for_promotion?).to be(false)
    end
  end
end
