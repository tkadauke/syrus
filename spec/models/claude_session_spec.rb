require "rails_helper"

class ClaudeSessionSpecOwner < ApplicationRecord
  self.table_name = "jobs"

  has_one :claude_session, as: :resumable
end

RSpec.describe ClaudeSession do
  let(:run) { Factories.job.initial_run }

  describe "validations + association" do
    it "requires a session_id" do
      s = described_class.new(resumable: run, session_id: "")
      expect(s).not_to be_valid
      expect(s.errors[:session_id]).to be_present
    end

    it "requires a resumable" do
      s = described_class.new(session_id: "uuid")
      expect(s).not_to be_valid
    end

    it "validates provider" do
      s = described_class.new(resumable: run, session_id: "uuid", provider: "oracle")
      expect(s).not_to be_valid
      expect(s.errors[:provider]).to be_present
    end

    it "destroys with the parent Run" do
      s = described_class.create!(resumable: run, session_id: "uuid", transcript_jsonl: "x")
      expect { run.destroy }.to change { described_class.where(id: s.id).count }.by(-1)
    end

    it "keeps Run#claude_session working through the polymorphic association" do
      session = run.create_claude_session!(session_id: "uuid", transcript_jsonl: "x")

      expect(run.reload.claude_session).to eq(session)
      expect(session.resumable).to eq(run)
      expect(session.run_id).to eq(run.id)
    end

    it "allows another model to own a ClaudeSession through the same polymorphic interface" do
      owner = ClaudeSessionSpecOwner.find(Factories.job.id)
      session = owner.create_claude_session!(session_id: "uuid", transcript_jsonl: "x")

      expect(owner.reload.claude_session).to eq(session)
      expect(session.resumable).to eq(owner)
      expect(session.run_id).to be_nil
    end
  end

  describe ".canonical_path_for" do
    it "encodes the cwd by replacing every / and . with -" do
      path = described_class.canonical_path_for(home: "/home/rails", cwd: "/syrus-home/.syrus/runs/40", session_id: "abc-123")
      # claude-code encodes both / and . to a single dash, so /.syrus
      # becomes --syrus (slash + dot → two dashes). Verified
      # empirically against a live worker — getting this wrong made
      # every session capture silently miss the JSONL on disk, which
      # broke --resume across the board.
      expect(path).to eq("/home/rails/.claude/projects/-syrus-home--syrus-runs-40/abc-123.jsonl")
    end

    it "handles a trailing slash on cwd" do
      path = described_class.canonical_path_for(home: "/h", cwd: "/a/b/", session_id: "id")
      expect(path).to eq("/h/.claude/projects/-a-b-/id.jsonl")
    end

    it "encodes dots in path segments (not just slashes)" do
      path = described_class.canonical_path_for(home: "/h", cwd: "/a/.foo/b", session_id: "id")
      expect(path).to eq("/h/.claude/projects/-a--foo-b/id.jsonl")
    end
  end

  describe ".with_succeeded_transcript" do
    it "includes succeeded Runs that still have a non-nil transcript_jsonl" do
      succeeded_run = Factories.job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      session = described_class.create!(resumable: succeeded_run, session_id: "s", transcript_jsonl: "data")
      expect(described_class.with_succeeded_transcript).to include(session)
    end

    it "excludes succeeded Runs whose transcript_jsonl is already nil" do
      succeeded_run = Factories.job.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
      session = described_class.create!(resumable: succeeded_run, session_id: "s", transcript_jsonl: nil)
      expect(described_class.with_succeeded_transcript).not_to include(session)
    end

    it "excludes failed and cancelled Runs regardless of transcript content" do
      failed_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
      session = described_class.create!(resumable: failed_run, session_id: "f", transcript_jsonl: "data")
      expect(described_class.with_succeeded_transcript).not_to include(session)
    end
  end

  describe ".prunable" do
    it "includes sessions whose Run is terminal AND older than RETAIN_AFTER_TERMINAL" do
      old_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }
      new_run = Factories.job.initial_run.tap { |r| r.start!; r.fail!; r.save! }

      old_session = described_class.create!(resumable: old_run, session_id: "old", transcript_jsonl: "x")
      new_session = described_class.create!(resumable: new_run, session_id: "new", transcript_jsonl: "x")
      old_session.update_columns(updated_at: (described_class::RETAIN_AFTER_TERMINAL + 1.day).ago)

      expect(described_class.prunable.pluck(:id)).to eq([ old_session.id ])
      expect(described_class.prunable).not_to include(new_session)
    end

    it "excludes sessions whose Run is still active even if old" do
      active_run = Factories.job.initial_run  # state=queued
      session = described_class.create!(resumable: active_run, session_id: "active", transcript_jsonl: "x")
      session.update_columns(updated_at: 1.year.ago)

      expect(described_class.prunable).not_to include(session)
    end
  end
end
