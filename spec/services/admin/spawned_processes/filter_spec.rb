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

  describe "outcome" do
    it "filters finished processes by how they ended" do
      failed = process(finished_at: 1.minute.ago, outcome: "failed", exit_status: 1)
      process(finished_at: 1.minute.ago, outcome: "succeeded", exit_status: 0)
      process # still running, outcome nil

      result = apply("field" => "outcome", "op" => "is", "value" => "failed")

      expect(result).to contain_exactly(failed)
    end

    it "matches any of several outcomes" do
      timed_out = process(finished_at: 1.minute.ago, outcome: "timed_out")
      killed = process(finished_at: 1.minute.ago, outcome: "operator_killed")
      process(finished_at: 1.minute.ago, outcome: "succeeded", exit_status: 0)

      result = apply("field" => "outcome", "op" => "is_one_of", "value" => %w[ timed_out operator_killed ])

      expect(result).to contain_exactly(timed_out, killed)
    end

    # `state` only distinguishes running from finished, so the two are not
    # interchangeable — asking `state is failed` is what silently broke the
    # Recently failed builtin.
    it "is not satisfied by the state chip" do
      process(finished_at: 1.minute.ago, outcome: "failed", exit_status: 1)

      result = apply("field" => "state", "op" => "is", "value" => "failed")

      expect(result).to be_empty
    end
  end

  describe "user_id" do
    it "filters workflow processes by the effective Job owner" do
      creator = Factories.user
      owner = Factories.user
      job = Factories.job(user: creator, owner_user: owner)
      workflow_process = process(workflow: job.latest_workflow)
      process

      result = apply("field" => "user_id", "op" => "is", "value" => owner.id.to_s)

      expect(result).to contain_exactly(workflow_process)
    end

    it "filters chat and preview processes by their owning users" do
      chat_user = Factories.user
      preview_user = Factories.user
      other_user = Factories.user
      chat = ChatSession.create!(user: chat_user, title: "Investigate queue")
      preview_job = Factories.job(user: preview_user)
      chat_process = process(kind: "chat_prepare", chat_session: chat)
      preview_process = process(kind: "preview", resource_attribution: { "job_id" => preview_job.id })
      process(kind: "chat_prepare", chat_session: ChatSession.create!(user: other_user, title: "Other"))

      chat_result = apply("field" => "user_id", "op" => "is", "value" => chat_user.id.to_s)
      preview_result = apply("field" => "user_id", "op" => "is", "value" => preview_user.id.to_s)

      expect(chat_result).to contain_exactly(chat_process)
      expect(preview_result).to contain_exactly(preview_process)
    end
  end

  # This builtin filtered `state is failed`, which the state chip does not
  # support, so it compiled to `1=0` and could never match. Its :when_present
  # visibility then hid it on every render — invisible rather than broken.
  it "applies the Recently failed builtin smart folder" do
    SmartFolder.ensure_spawned_process_builtins!
    recent_failure = process(started_at: 10.minutes.ago, finished_at: 5.minutes.ago, outcome: "failed", exit_status: 1)
    process(started_at: 10.minutes.ago, finished_at: 5.minutes.ago, outcome: "succeeded", exit_status: 0)
    process(started_at: 3.hours.ago, finished_at: 2.hours.ago, outcome: "failed", exit_status: 1)

    folder = SmartFolder.builtins(:spawned_process).find_by!(name: "Recently failed")
    relation = described_class.from_tree(folder.filter).apply(SpawnedProcess.all)

    expect(relation.to_sql).not_to include("1=0")
    expect(relation).to contain_exactly(recent_failure)
  end
end
