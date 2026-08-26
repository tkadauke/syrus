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

    it "reports promotion, hotfix sync as disabled" do
      expect(policy.promotion_enabled?).to be(false)
      expect(policy.hotfix_sync_enabled?).to be(false)
    end

    it "reports the default promotion/hotfix sync modes even when disabled" do
      expect(policy.promotion_mode).to eq("auto_pr")
      expect(policy.hotfix_sync_mode).to eq("auto")
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

    it "reports promotion and hotfix sync as enabled with their configured modes" do
      expect(policy.promotion_enabled?).to be(true)
      expect(policy.promotion_mode).to eq("manual_pr")
      expect(policy.hotfix_sync_enabled?).to be(true)
      expect(policy.hotfix_sync_mode).to eq("auto_pr")
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
