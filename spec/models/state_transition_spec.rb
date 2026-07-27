require "rails_helper"

RSpec.describe StateTransition do
  let(:job) { Factories.job }

  describe "validations" do
    it "requires from_state, to_state, source" do
      transition = described_class.new(subject: job)
      expect(transition).not_to be_valid
      expect(transition.errors[:from_state]).to be_present
      expect(transition.errors[:to_state]).to be_present
    end

    it "rejects unknown source" do
      transition = described_class.new(subject: job, from_state: "x", to_state: "y", source: "bogus")
      expect(transition).not_to be_valid
      expect(transition.errors[:source]).to be_present
    end

    it "accepts every documented source" do
      described_class::SOURCES.each do |src|
        transition = described_class.new(subject: job, from_state: "x", to_state: "y", source: src)
        expect(transition).to be_valid, "expected source=#{src} to be valid"
      end
    end
  end

  describe ".with_source" do
    it "sets a thread-local source for the duration of the block" do
      expect(described_class.current_source).to eq("aasm")

      described_class.with_source("propagate") do
        expect(described_class.current_source).to eq("propagate")
      end

      expect(described_class.current_source).to eq("aasm")
    end

    it "restores the prior source even when the block raises" do
      described_class.with_source("operator") do
        expect {
          described_class.with_source("reconciler") { raise "boom" }
        }.to raise_error("boom")

        expect(described_class.current_source).to eq("operator")
      end
    end

    it "rejects unknown sources" do
      expect { described_class.with_source("bogus") { } }
        .to raise_error(ArgumentError, /unknown source/)
    end
  end

  describe "automatic recording on AASM transitions" do
    it "records a transition row when a Job moves between states" do
      # Strip the factory-created Workflow + Run so we have a clean
      # baseline — the factory's setup itself fires transitions.
      job.workflows.destroy_all
      job.runs.destroy_all
      job.update!(state: "queued")
      starting_count = described_class.for_subject(job).count

      job.start_running!
      job.save!

      expect(described_class.for_subject(job).count).to eq(starting_count + 1)
      last = described_class.for_subject(job).recent.first
      expect(last.from_state).to eq("queued")
      expect(last.to_state).to eq("running")
      expect(last.event_name).to eq("start_running")
      expect(last.source).to eq("aasm")
    end

    it "tags transitions inside with_source('propagate') as :propagate" do
      job.workflows.destroy_all
      job.runs.destroy_all
      job.update!(state: "queued")

      described_class.with_source("propagate") do
        job.start_running!
        job.save!
      end

      expect(described_class.for_subject(job).recent.first.source).to eq("propagate")
    end

    it "cross-links to the in-flight Run when one is set on the thread" do
      job.workflows.destroy_all
      job.runs.destroy_all
      run = Run.create!(job: job, trigger_kind: "initial", state: "queued")
      job.update!(state: "queued")

      Thread.current[:syrus_current_run] = run
      job.start_running!
      job.save!

      expect(described_class.for_subject(job).recent.first.run_id).to eq(run.id)
    ensure
      Thread.current[:syrus_current_run] = nil
    end

    it "doesn't record a row when an AASM event no-ops (whiny_transitions: false)" do
      job.workflows.destroy_all
      job.runs.destroy_all
      job.update!(state: "queued")
      starting_count = described_class.for_subject(job).count

      # Job is :queued — mark_failed only transitions from :running, so
      # this no-ops silently (whiny_transitions: false).
      job.mark_failed
      job.save!

      expect(described_class.for_subject(job).count).to eq(starting_count)
    end

    it "logs a warning and does not raise when StateTransition.create! fails" do
      job.workflows.destroy_all
      job.runs.destroy_all
      job.update!(state: "queued")
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "disk full")
      allow(Rails.logger).to receive(:warn)

      # The state machine transition must succeed even though the audit write fails.
      expect { job.start_running!; job.save! }.not_to raise_error
      expect(job.reload.state).to eq("running")
      expect(Rails.logger).to have_received(:warn).with(/failed to record Job##{job.id}/)
    end
  end
end
