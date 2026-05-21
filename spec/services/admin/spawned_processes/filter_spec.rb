require "rails_helper"

RSpec.describe Admin::SpawnedProcesses::Filter do
  def process(**overrides)
    SpawnedProcess.create!({
      kind: "agent",
      command: "claude --print",
      hostname: "syrus-worker-test",
      started_at: 30.seconds.ago,
      last_chunk_at: 5.seconds.ago
    }.merge(overrides))
  end

  def apply(tree)
    described_class.from_tree(tree).apply(SpawnedProcess.all)
  end

  it "filters by running state" do
    running = process
    process(finished_at: 1.minute.ago, outcome: "succeeded", exit_status: 0)

    result = apply("field" => "state", "op" => "is", "value" => "running")

    expect(result).to contain_exactly(running)
  end

  it "filters by kind" do
    process(kind: "agent")
    grader = process(kind: "grader", command: "bin/rspec")

    result = apply("field" => "kind", "op" => "is", "value" => "grader")

    expect(result).to contain_exactly(grader)
  end

  it "filters by stale rows using the SpawnedProcess stale scope" do
    fresh = process(last_chunk_at: 1.minute.ago)
    stale = process(last_chunk_at: 10.minutes.ago)
    process(started_at: 10.minutes.ago, finished_at: Time.current, outcome: "succeeded")

    result = apply("field" => "stale", "op" => "is", "value" => "true")

    expect(result).to contain_exactly(stale)
    expect(result).not_to include(fresh)
  end

  it "defaults to running or finished within the last hour" do
    running = process
    recent = process(started_at: 5.minutes.ago, finished_at: 1.minute.ago, outcome: "succeeded")
    process(started_at: 5.hours.ago, finished_at: 4.hours.ago, outcome: "succeeded")

    result = described_class.from_params({}).apply(SpawnedProcess.all)

    expect(result).to contain_exactly(running, recent)
  end

  it "applies the Stale builtin smart folder" do
    SmartFolder.ensure_spawned_process_builtins!
    stale = process(last_chunk_at: 10.minutes.ago)
    process(last_chunk_at: 1.minute.ago)

    folder = SmartFolder.builtins(:spawned_process).find_by!(name: "Stale")
    result = described_class.from_tree(folder.filter).apply(SpawnedProcess.all)

    expect(result).to contain_exactly(stale)
  end
end
