require "rails_helper"

RSpec.describe JobLog do
  let(:run) { Factories.run }

  it "allows chunks at least as large as the step log buffer cap" do
    expect(described_class.columns_hash.fetch("chunk").limit).to be >= Steps::Base::LOG_FLUSH_MAX_BUF
  end

  it "appends chunks ordered by sequence" do
    JobLog.create!(run: run, chunk: "second", sequence: 1)
    JobLog.create!(run: run, chunk: "first",  sequence: 0)
    expect(run.reload.job_logs.map(&:chunk)).to eq(%w[first second])
  end

  it "appends the next sequence" do
    JobLog.create!(run: run, chunk: "first", sequence: 0)

    log = described_class.append!(run: run, chunk: "second", kind: "system")

    expect(log.sequence).to eq(1)
    expect(log.kind).to eq("system")
    expect(run.reload.job_logs.order(:sequence).pluck(:chunk)).to eq(%w[first second])
  end

  it "does not reload or save dirty state on the caller's run instance" do
    run.assign_attributes(prompt: "dirty in memory")

    described_class.append!(run: run, chunk: "log line")

    expect(run.prompt).to eq("dirty in memory")
    expect(run).to be_changed
  end

  it "does not persist blank append chunks" do
    expect(described_class.append!(run: run, chunk: "   \n", kind: "system")).to be_nil
    expect(run.job_logs.count).to eq(0)
  end

  it "normalizes binary-tagged UTF-8 chunks before persisting" do
    log = described_class.append!(run: run, chunk: "● Bash(ls)\n".b, kind: "tool_call")

    expect(log.chunk).to eq("● Bash(ls)\n")
    expect(log.chunk.encoding).to eq(Encoding::UTF_8)
  end

  it "rejects update — append-only" do
    log = JobLog.create!(run: run, chunk: "hello", sequence: 0)
    expect { log.update!(chunk: "rewritten") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "rejects direct destroy — append-only" do
    log = JobLog.create!(run: run, chunk: "hello", sequence: 0)
    expect { log.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "permits cascading destroy when parent Run goes away" do
    JobLog.create!(run: run, chunk: "hello", sequence: 0)
    expect { run.destroy! }.not_to raise_error
    expect(JobLog.where(run_id: run.id).count).to eq(0)
  end

  it "permits cascading destroy when parent Job goes away" do
    JobLog.create!(run: run, chunk: "hello", sequence: 0)
    job = run.job
    expect { job.destroy! }.not_to raise_error
    expect(JobLog.where(run_id: run.id).count).to eq(0)
  end

  it "enforces unique sequence per run, not per job" do
    job = Factories.job
    run1 = job.initial_run
    run2 = Run.create!(job: job, trigger_kind: "pr_comment")
    JobLog.create!(run: run1, chunk: "a", sequence: 0)
    # Same sequence on a different Run is fine — they're independent transcripts.
    expect { JobLog.create!(run: run2, chunk: "b", sequence: 0) }.not_to raise_error
    # Same sequence on the SAME run is rejected.
    dup = JobLog.new(run: run1, chunk: "c", sequence: 0)
    expect(dup).not_to be_valid
  end
end
