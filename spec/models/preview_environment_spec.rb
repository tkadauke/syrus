require "rails_helper"

RSpec.describe PreviewEnvironment, type: :model do
  let(:job) { Factories.job }

  def build_env(**attrs)
    described_class.new({ job: job, workspace_path: "/tmp/workspace" }.merge(attrs))
  end

  def create_env(**attrs)
    described_class.create!({ job: job, workspace_path: "/tmp/workspace" }.merge(attrs))
  end

  describe "validations" do
    it "is valid with required attributes" do
      expect(build_env).to be_valid
    end

    it "requires job" do
      expect(build_env(job: nil)).not_to be_valid
    end

    it "requires state" do
      env = build_env
      env.state = nil
      expect(env).not_to be_valid
    end

    it "rejects unknown states" do
      expect(build_env(state: "unknown")).not_to be_valid
    end

    it "accepts all defined states" do
      described_class::STATES.each do |state|
        env = build_env(state: state)
        env.validate
        expect(env.errors[:state]).to be_empty
      end
    end

    it "rejects error_message on non-failed environments" do
      env = build_env(state: "running", error_message: "oops")
      expect(env).not_to be_valid
      expect(env.errors[:error_message]).not_to be_empty
    end

    it "allows error_message on failed environments" do
      env = build_env(state: "failed", error_message: "process crashed")
      expect(env).to be_valid
    end
  end

  describe "uniqueness constraint: only one active preview per job" do
    it "allows creating a preview when none is active" do
      expect { create_env }.not_to raise_error
    end

    it "prevents a second active preview for the same job" do
      create_env
      second = build_env
      expect(second).not_to be_valid
      expect(second.errors[:job]).to include("already has an active preview environment")
    end

    it "allows a new preview when the existing one is stopped" do
      create_env(state: "stopped")
      expect { create_env }.not_to raise_error
    end

    it "allows a new preview when the existing one is failed" do
      create_env(state: "failed")
      expect { create_env }.not_to raise_error
    end

    it "allows active previews for different jobs" do
      other_job = Factories.job
      create_env
      expect { create_env(job: other_job) }.not_to raise_error
    end

    described_class::ACTIVE_STATES.each do |active_state|
      it "blocks a second preview when existing is '#{active_state}'" do
        create_env(state: active_state)
        expect(build_env).not_to be_valid
      end
    end
  end

  describe "AASM state machine" do
    it "starts in the starting state" do
      env = build_env
      expect(env.state).to eq("starting")
    end

    it "transitions starting → seeding" do
      env = create_env
      expect(env.may_begin_seeding?).to be true
      env.begin_seeding!
      env.save!
      expect(env.reload.state).to eq("seeding")
    end

    it "transitions seeding → running" do
      env = create_env(state: "seeding")
      expect(env.may_mark_running?).to be true
      env.mark_running!
      env.save!
      expect(env.reload.state).to eq("running")
    end

    it "sets last_activity_at when transitioning to running" do
      freeze_time do
        env = create_env(state: "seeding")
        env.mark_running!
        env.save!
        expect(env.reload.last_activity_at).to be_within(1.second).of(Time.current)
      end
    end

    it "sets expires_at when transitioning to running" do
      freeze_time do
        env = create_env(state: "seeding")
        env.mark_running!
        env.save!
        expect(env.reload.expires_at).to be_within(1.second).of(
          PreviewEnvironment::DEFAULT_TTL_MINUTES.minutes.from_now
        )
      end
    end

    it "transitions running → stopping via begin_stopping" do
      env = create_env(state: "running")
      env.begin_stopping!
      env.save!
      expect(env.reload.state).to eq("stopping")
    end

    it "transitions stopping → stopped" do
      env = create_env(state: "stopping")
      env.mark_stopped!
      env.save!
      expect(env.reload.state).to eq("stopped")
    end

    it "fails from any active state" do
      %w[ starting seeding running stopping ].each do |state|
        env = create_env(state: state, job: Factories.job)
        expect(env.may_fail?).to be true
      end
    end

    it "cannot fail from terminal states" do
      %w[ stopped failed ].each do |state|
        env = create_env(state: state)
        expect(env.may_fail?).to be false
      end
    end

    it "cannot transition seeding → stopped (must go through stopping)" do
      env = create_env(state: "seeding")
      expect(env.may_mark_stopped?).to be false
    end
  end

  describe "scopes" do
    it ".active returns environments in any active state" do
      active_envs = described_class::ACTIVE_STATES.map { |s| create_env(state: s, job: Factories.job) }
      create_env(state: "stopped", job: Factories.job)
      create_env(state: "failed", job: Factories.job)

      expect(described_class.active).to match_array(active_envs)
    end

    it ".expired returns running environments past their expires_at" do
      expired = create_env(state: "running", expires_at: 1.minute.ago)
      _fresh  = create_env(state: "running", expires_at: 5.minutes.from_now,
                            job: Factories.job)
      _no_ttl = create_env(state: "running", expires_at: nil, job: Factories.job)

      expect(described_class.expired).to eq([ expired ])
    end

    it ".expired excludes non-running environments even if past expires_at" do
      create_env(state: "stopping", expires_at: 1.minute.ago)
      expect(described_class.expired).to be_empty
    end
  end

  describe "#active?" do
    it "returns true for active states" do
      described_class::ACTIVE_STATES.each do |state|
        expect(build_env(state: state).active?).to be true
      end
    end

    it "returns false for terminal states" do
      %w[ stopped failed ].each do |state|
        expect(build_env(state: state).active?).to be false
      end
    end
  end

  describe "#preview_url" do
    it "constructs a subdomain-based URL" do
      env = build_env
      env.job = Factories.job
      url = env.preview_url("syrus.example.com")
      expect(url).to eq("http://preview-#{env.job_id}.syrus.example.com")
    end
  end

  describe "#touch_activity!" do
    it "updates last_activity_at and extends expires_at" do
      env = create_env(state: "running")
      freeze_time do
        env.touch_activity!
        env.reload
        expect(env.last_activity_at).to be_within(1.second).of(Time.current)
        expect(env.expires_at).to be_within(1.second).of(
          PreviewEnvironment::DEFAULT_TTL_MINUTES.minutes.from_now
        )
      end
    end
  end
end
