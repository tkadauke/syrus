require "rails_helper"
require "tmpdir"

RSpec.describe ChatWorkspacePrepareJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user) }

  before do
    @data_root = Dir.mktmpdir("syrus-chatws-prep")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(@data_root) if @data_root
  end

  def checkout_path
    ChatWorkspace.repo_path_for(chat_session, repository)
  end

  def make_checkout_path
    path = checkout_path
    FileUtils.mkdir_p(path.join(".git").to_s)
    path
  end

  def success_result
    ProcessRunner::Result.new(
      exit_status: 0, timed_out: false, stopped: false, silent_timed_out: false,
      operator_killed: false, aliveness_failed: false, duration_s: 1.0,
      spawned_process_id: nil
    )
  end

  def failure_result
    ProcessRunner::Result.new(
      exit_status: 1, timed_out: false, stopped: false, silent_timed_out: false,
      operator_killed: false, aliveness_failed: false, duration_s: 1.0,
      spawned_process_id: nil
    )
  end

  it "runs on the chat queue" do
    expect(described_class.new.queue_name).to eq("chat")
  end

  it "no-ops when the checkout directory does not exist" do
    expect(RepoPrepPlan).not_to receive(:for)
    expect { described_class.perform_now(chat_session.id, repository.id) }.not_to raise_error
  end

  it "no-ops when the plan has no commands" do
    make_checkout_path
    plan = RepoPrepPlan::Result.new(commands: [], source: ".syrus.yml", note: "opted out")
    allow(RepoPrepPlan).to receive(:for).and_return(plan)

    expect(ProcessRunner).not_to receive(:new)
    expect { described_class.perform_now(chat_session.id, repository.id) }.not_to raise_error
  end

  it "runs each prep command with a scrubbed env, bash wrapper, and 10-minute timeout" do
    path = make_checkout_path
    plan = RepoPrepPlan::Result.new(commands: [ "bundle install" ], source: ".syrus.yml", note: nil)
    allow(RepoPrepPlan).to receive(:for).and_return(plan)

    runner_double = double("ProcessRunner", run: success_result)
    expect(ProcessRunner).to receive(:new).with(
      hash_including(
        command: [ "bash", "-c", "bundle install" ],
        chdir: path,
        timeout: described_class::PER_COMMAND_TIMEOUT,
        kind: "chat_prepare"
      )
    ).and_return(runner_double)

    described_class.perform_now(chat_session.id, repository.id)
  end

  it "runs all commands when each succeeds" do
    make_checkout_path
    plan = RepoPrepPlan::Result.new(commands: [ "bundle install", "npm ci" ], source: ".syrus.yml", note: nil)
    allow(RepoPrepPlan).to receive(:for).and_return(plan)

    runner_double = double("ProcessRunner", run: success_result)
    expect(ProcessRunner).to receive(:new).twice.and_return(runner_double)

    described_class.perform_now(chat_session.id, repository.id)
  end

  context "with a guessed (auto-detected) plan" do
    before do
      make_checkout_path
      plan = RepoPrepPlan::Result.new(
        commands: [ "npm ci" ],
        source: "auto-detect (package-lock.json)",
        note: nil
      )
      allow(RepoPrepPlan).to receive(:for).and_return(plan)
    end

    it "logs a warning on failure and does not raise" do
      runner_double = double("ProcessRunner", run: failure_result)
      allow(ProcessRunner).to receive(:new).and_return(runner_double)

      expect(Rails.logger).to receive(:warn).with(/guessed setup command failed/)
      expect { described_class.perform_now(chat_session.id, repository.id) }.not_to raise_error
    end

    it "stops running further commands after the first guessed failure" do
      two_cmd_plan = RepoPrepPlan::Result.new(
        commands: [ "npm ci", "npm test" ],
        source: "auto-detect (package-lock.json)",
        note: nil
      )
      allow(RepoPrepPlan).to receive(:for).and_return(two_cmd_plan)

      runner_double = double("ProcessRunner", run: failure_result)
      expect(ProcessRunner).to receive(:new).once.and_return(runner_double)

      allow(Rails.logger).to receive(:warn)
      described_class.perform_now(chat_session.id, repository.id)
    end
  end

  context "with an explicit .syrus.yml plan" do
    before do
      make_checkout_path
      plan = RepoPrepPlan::Result.new(
        commands: [ "bundle install" ],
        source: ".syrus.yml",
        note: nil
      )
      allow(RepoPrepPlan).to receive(:for).and_return(plan)
    end

    it "logs an error on failure and does not raise" do
      runner_double = double("ProcessRunner", run: failure_result)
      allow(ProcessRunner).to receive(:new).and_return(runner_double)

      expect(Rails.logger).to receive(:error).with(/explicit .syrus.yml command failed/)
      expect { described_class.perform_now(chat_session.id, repository.id) }.not_to raise_error
    end

    it "stops running further commands after an explicit failure" do
      two_cmd_plan = RepoPrepPlan::Result.new(
        commands: [ "bundle install", "npm ci" ],
        source: ".syrus.yml",
        note: nil
      )
      allow(RepoPrepPlan).to receive(:for).and_return(two_cmd_plan)

      runner_double = double("ProcessRunner", run: failure_result)
      expect(ProcessRunner).to receive(:new).once.and_return(runner_double)

      allow(Rails.logger).to receive(:error)
      described_class.perform_now(chat_session.id, repository.id)
    end
  end
end
