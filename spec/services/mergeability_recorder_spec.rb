require "rails_helper"

RSpec.describe MergeabilityRecorder do
  PrStub = Struct.new(:mergeable, :mergeable_state, :head, :base, keyword_init: true)
  RefStub = Struct.new(:sha, :ref, keyword_init: true)

  def make_pr(mergeable: true, mergeable_state: "clean", head_sha: "abc123", base_sha: "def456", base_ref: "main")
    PrStub.new(
      mergeable: mergeable,
      mergeable_state: mergeable_state,
      head: RefStub.new(sha: head_sha, ref: nil),
      base: RefStub.new(sha: base_sha, ref: base_ref)
    )
  end

  describe ".head_sha" do
    it "returns the head SHA from the PR" do
      pr = make_pr(head_sha: "deadbeef")
      expect(described_class.head_sha(pr)).to eq("deadbeef")
    end

    it "returns nil when PR is nil" do
      expect(described_class.head_sha(nil)).to be_nil
    end
  end

  describe ".base_sha" do
    it "returns the base SHA from the PR" do
      pr = make_pr(base_sha: "cafebabe")
      expect(described_class.base_sha(pr)).to eq("cafebabe")
    end

    it "returns nil when PR is nil" do
      expect(described_class.base_sha(nil)).to be_nil
    end
  end

  describe ".base_ref" do
    it "returns the base ref from the PR" do
      pr = make_pr(base_ref: "main")
      expect(described_class.base_ref(pr)).to eq("main")
    end

    it "returns nil when the base ref is blank" do
      pr = make_pr(base_ref: "")
      expect(described_class.base_ref(pr)).to be_nil
    end

    it "returns nil when PR is nil" do
      expect(described_class.base_ref(nil)).to be_nil
    end
  end

  describe ".github_state" do
    it "returns the mergeable_state from the PR" do
      pr = make_pr(mergeable_state: "dirty")
      expect(described_class.github_state(pr)).to eq("dirty")
    end

    it "returns nil when PR is nil" do
      expect(described_class.github_state(nil)).to be_nil
    end
  end

  describe ".record_github!" do
    let(:job) { Factories.job }

    it "records GitHub mergeability fields on the job" do
      pr = make_pr(mergeable: true, mergeable_state: "clean", head_sha: "aaa", base_sha: "bbb", base_ref: "main")
      freeze_time do
        described_class.record_github!(job: job, pr: pr, checked_at: Time.current)

        job.reload
        expect(job.pr_mergeable).to be true
        expect(job.github_mergeable).to be true
        expect(job.github_mergeable_state).to eq("clean")
        expect(job.mergeability_head_sha).to eq("aaa")
        expect(job.mergeability_base_sha).to eq("bbb")
        expect(job.mergeability_base_ref).to eq("main")
        expect(job.mergeability_checked_at).to be_within(1.second).of(Time.current)
      end
    end

    it "records unmergeable state when the PR has conflicts" do
      pr = make_pr(mergeable: false, mergeable_state: "dirty")

      described_class.record_github!(job: job, pr: pr)

      job.reload
      expect(job.pr_mergeable).to be false
      expect(job.github_mergeable_state).to eq("dirty")
    end
  end

  describe ".record_local!" do
    let(:job) { Factories.job }

    it "records local mergeability results on the job" do
      result = LocalMergeabilityCheck::Result.new(
        state: "clean",
        mergeable: true,
        message: "rebase passed",
        head_sha: "head111",
        base_sha: "base222",
        base_ref: "main"
      )

      freeze_time do
        described_class.record_local!(job: job, result: result, checked_at: Time.current)

        job.reload
        expect(job.local_mergeable).to be true
        expect(job.local_mergeable_state).to eq("clean")
        expect(job.local_mergeability_head_sha).to eq("head111")
        expect(job.local_mergeability_base_sha).to eq("base222")
        expect(job.local_mergeability_checked_at).to be_within(1.second).of(Time.current)
      end
    end

    it "records conflict state from a failed local rebase" do
      result = LocalMergeabilityCheck::Result.new(
        state: "conflict",
        mergeable: false,
        message: "conflicts found",
        head_sha: nil,
        base_sha: nil,
        base_ref: "main"
      )

      described_class.record_local!(job: job, result: result)

      job.reload
      expect(job.local_mergeable).to be false
      expect(job.local_mergeable_state).to eq("conflict")
    end
  end
end
