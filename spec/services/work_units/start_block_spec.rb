require "rails_helper"

RSpec.describe WorkUnits::StartBlock do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { WorkUnits::Launcher.instantiate(kind: "initial", job: job) }

  it "prefers WorkUnit blocked state over legacy workflow start-block artifacts" do
    artifact_next_check_at = 5.minutes.from_now
    work_unit_blocked_until = 20.minutes.from_now
    workflow.update!(
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_details" => { "reason" => "budget" },
        "start_blocked_next_check_at" => artifact_next_check_at.iso8601
      }
    )
    workflow.work_unit.block!(
      reason: "provider_availability",
      blocked_until: work_unit_blocked_until,
      details: { "provider" => "codex" }
    )

    block = described_class.for(workflow)

    expect(block.reason).to eq("provider_availability")
    expect(block.details).to eq("provider" => "codex")
    expect(block.next_check_at).to be_within(2.seconds).of(work_unit_blocked_until)
    expect(block.data).to include(
      reason: "provider_availability",
      next_check_at: work_unit_blocked_until.iso8601,
      details: { "provider" => "codex" }
    )
  end

  it "ignores legacy workflow start-block artifacts on WorkUnit-owned workflows" do
    next_check_at = 5.minutes.from_now
    workflow.update!(
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_details" => { "reason" => "budget" },
        "start_blocked_next_check_at" => next_check_at.iso8601
      }
    )

    block = described_class.for(workflow)

    expect(block.reason).to be_nil
    expect(block.details).to eq({})
    expect(block.next_check_at).to be_nil
    expect(block.blocked_for?(StepDispatcher::ADMISSION_BLOCK_REASON)).to be(false)
    expect(block.data).to eq({})
  end

  it "ignores start-block artifacts on legacy replay workflows" do
    replay = Workflow.create!(job: job, trigger_kind: "replay", state: "queued")
    replay.update!(
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_details" => { "reason" => "budget" },
        "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
      }
    )

    block = described_class.for(replay)

    expect(block.reason).to be_nil
    expect(block.details).to eq({})
    expect(block.next_check_at).to be_nil
    expect(block.blocked_for?(StepDispatcher::ADMISSION_BLOCK_REASON)).to be(false)
    expect(block.data).to eq({})
  end

  it "ignores start-block artifacts on unowned non-replay workflows" do
    migrated = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
    migrated.update!(
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_details" => { "reason" => "budget" },
        "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
      }
    )

    block = described_class.for(migrated)

    expect(block.reason).to be_nil
    expect(block.details).to eq({})
    expect(block.next_check_at).to be_nil
    expect(block.blocked_for?(StepDispatcher::ADMISSION_BLOCK_REASON)).to be(false)
    expect(block.data).to eq({})
  end

  it "falls back to WorkUnit blocked state when workflow artifacts are absent" do
    blocked_until = 10.minutes.from_now
    workflow.work_unit.block!(
      reason: "main_branch_health",
      blocked_until: blocked_until,
      details: { "repository_id" => repository.id }
    )

    block = described_class.for(workflow)

    expect(block.reason).to eq("main_branch_health")
    expect(block.details).to include("repository_id" => repository.id)
    expect(block.next_check_at).to be_within(2.seconds).of(blocked_until)
    expect(block.data).to include(
      reason: "main_branch_health",
      next_check_at: blocked_until.iso8601,
      details: include("repository_id" => repository.id)
    )
    expect(block.blocked_for?(StepDispatcher::MAIN_HEALTH_BLOCK_REASON)).to be(true)
  end
end
