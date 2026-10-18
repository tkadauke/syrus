require "rails_helper"
require "tmpdir"

# ProcessRunner's SpawnedProcess row, in isolation from spawning anything. The
# row is observability -- the supervisor reads it to reap strays, the admin UI
# reads it to show what is running -- so what matters here is that asking for
# it, or failing to get it, never decides whether a subprocess may run.
RSpec.describe ProcessRunner, "spawned process registration" do
  # The supervisor thread is a side effect of passing `kind:`; this spec is
  # about the row, and a background thread per example is nobody's friend.
  before { allow(SpawnedProcessSupervisor).to receive(:ensure_running) }

  def runner(**overrides)
    described_class.new(
      env: {},
      command: [ "/bin/true" ],
      mounts: described_class.mounts(Dir.tmpdir),
      network: "grader",
      timeout: 5,
      **overrides
    )
  end

  def register(**overrides)
    runner(**overrides).send(:register_spawned_process)
  end

  it "records a tracked spawn" do
    process = nil

    expect { process = register(kind: "grader") }.to change(SpawnedProcess, :count).by(1)
    expect(process.kind).to eq("grader")
    expect(process.hostname).to eq(Socket.gethostname)
  end

  it "records nothing for an untracked spawn" do
    expect { expect(register).to be_nil }.not_to change(SpawnedProcess, :count)
  end

  # Regression: this raised, so a database that was unreachable -- or simply
  # absent, as during `docker build`'s assets:precompile -- killed subprocesses
  # that had nothing to do with the database. ProcessRunner still enforces its
  # own wall and silent timeouts in-process, and the `kind:`-less path above
  # already proves a runner works with no row, so degrading is safe.
  it "degrades to no row when there is no database to write to" do
    allow(SpawnedProcess).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { expect(register(kind: "grader")).to be_nil }.not_to raise_error
  end

  it "degrades the same way when the database does not exist" do
    allow(SpawnedProcess).to receive(:create!).and_raise(ActiveRecord::NoDatabaseError)

    expect(register(kind: "grader")).to be_nil
  end

  # Only "there is no database" degrades. A row we could have written and
  # didn't is a bug, and swallowing it would hide the next one.
  it "still raises when the row itself is bad" do
    allow(SpawnedProcess).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(SpawnedProcess.new))

    expect { register(kind: "grader") }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
