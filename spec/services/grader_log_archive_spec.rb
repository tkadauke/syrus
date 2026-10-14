require "rails_helper"
require "tmpdir"

RSpec.describe GraderLogArchive do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:grader_step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 10,
      iteration: 2,
      state: "failed",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago,
      details: {
        "name" => "rspec",
        "required" => true,
        "command" => "bin/rspec",
        "exit_code" => 1
      }
    )
  end
  let(:grader_run) do
    grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed", iteration: 2)
  end

  around do |example|
    Dir.mktmpdir("syrus-grader-log-archive") do |dir|
      @workspace = Pathname.new(dir)
      example.run
    end
  end

  def stream!(chunks, run: grader_run)
    chunks.each_with_index do |chunk, index|
      JobLog.create!(run: run, kind: "grade_log", chunk: chunk, sequence: index)
    end
  end

  def write!(step: grader_step, iteration: 2)
    described_class.new(step: step, iteration: iteration, workspace_path: @workspace).write!
  end

  describe "#write!" do
    # The grader keeps only a failure-focused excerpt on Step#details, and its
    # own log file is in whichever workspace that grader ran in. The streamed
    # chunks are the only complete, machine-independent copy, so the archive
    # has to reassemble from them without dropping anything.
    it "writes the grader's complete output, reassembled from the streamed chunks" do
      chunks = Array.new(600) { |i| "line #{i}\n" }
      stream!(chunks)

      entry = write!

      path = @workspace.join(entry["relative_path"])
      expect(path).to exist
      expect(path.read).to eq(chunks.join)
      expect(entry["bytes"]).to eq(chunks.join.bytesize)
      expect(entry["unavailable_reason"]).to be_nil
    end

    it "names the log by iteration and grader so several failures can coexist" do
      stream!([ "boom\n" ])

      entry = write!

      expect(entry["relative_path"]).to eq(".syrus/grade-logs/iteration-2/rspec.log")
    end

    it "sanitizes a grader name that would not be a safe filename" do
      grader_step.update!(details: grader_step.details.merge("name" => "react tests/focused"))
      stream!([ "boom\n" ])

      entry = write!

      expect(entry["relative_path"]).to eq(".syrus/grade-logs/iteration-2/react-tests-focused.log")
      expect(@workspace.join(entry["relative_path"])).to exist
    end

    # The preview exists to tell the agent which log to open. Previewing the
    # head of a test run shows boot noise; the failure lines are the point.
    it "previews the failure lines rather than the head of the log" do
      stream!([
        "Booting Rails\n",
        ("passing dot\n" * 500),
        "Failures:\n",
        "  1) Thing does the thing\n",
        "rspec ./spec/thing_spec.rb:12 # Thing does the thing\n"
      ])

      entry = write!

      expect(entry["preview"]).to include("Failures:")
      expect(entry["preview"]).to include("rspec ./spec/thing_spec.rb:12")
      expect(entry["preview"]).not_to include("Booting Rails")
    end

    it "falls back to the log tail when nothing in it looks like a failure" do
      stream!([ "quiet start\n", ("middle\n" * 400), "the last thing that happened\n" ])

      entry = write!

      expect(entry["preview"]).to include("the last thing that happened")
      expect(entry["preview"]).not_to include("quiet start")
    end

    it "caps the preview even when the failure lines are enormous" do
      stream!([ "Failures:\n" ] + Array.new(200) { |i| "  #{i}) #{'x' * 200}\n" })

      entry = write!

      expect(entry["preview"].bytesize).to be <= described_class::PREVIEW_MAX_BYTES
      expect(@workspace.join(entry["relative_path"]).size).to be > described_class::PREVIEW_MAX_BYTES
    end

    it "reassembles chunks across a retried grader's runs in run order" do
      first = grader_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "failed", iteration: 2)
      stream!([ "from the first run\n" ], run: first)
      stream!([ "from the second run\n" ], run: grader_run)

      entry = write!

      expect(@workspace.join(entry["relative_path"]).read).to eq("from the first run\nfrom the second run\n")
    end

    # "No output" is not a short log -- it is a grader that never produced
    # anything, which reads completely differently to a repair agent. It gets
    # an explicit reason instead of a blank section.
    context "when the grader produced no output at all" do
      it "records why there is no log instead of writing an empty one" do
        entry = write!

        expect(entry["bytes"]).to eq(0)
        expect(entry["relative_path"]).to be_nil
        expect(entry["unavailable_reason"]).to be_present
        expect(@workspace.join(".syrus/grade-logs")).not_to exist
      end

      it "distinguishes a grader that never started from one that died mid-run" do
        grader_step.update!(started_at: nil, finished_at: nil, details: grader_step.details.except("exit_code"))
        expect(write!["unavailable_reason"]).to match(/never started/)

        grader_step.update!(started_at: 2.minutes.ago, details: grader_step.details.except("exit_code"))
        expect(write!["unavailable_reason"]).to match(/worker most likely died/)
      end

      it "explains a cancelled grader Step as cancelled" do
        grader_step.update!(state: "cancelled")

        expect(write!["unavailable_reason"]).to match(/cancelled/)
      end
    end
  end

  # The repair step routinely runs on a different worker than the graders and
  # the collect step did, so it cannot assume the files are on its disk. The
  # manifest plus the durable chunk stream is what makes the path it is given
  # actually resolve.
  describe ".materialize!" do
    it "recreates the logs in a different workspace from the manifest" do
      stream!([ "the failure detail\n" ])
      entry = write!

      Dir.mktmpdir("syrus-other-worker") do |other|
        other_path = Pathname.new(other)
        expect(other_path.join(entry["relative_path"])).not_to exist

        described_class.materialize!(entries: [ entry ], workspace_path: other_path)

        expect(other_path.join(entry["relative_path"]).read).to eq("the failure detail\n")
      end
    end

    it "skips entries whose grader produced no output" do
      entry = write!

      expect {
        described_class.materialize!(entries: [ entry ], workspace_path: @workspace)
      }.not_to raise_error
      expect(@workspace.join(".syrus/grade-logs")).not_to exist
    end

    it "ignores an entry whose grader Step no longer exists" do
      stream!([ "gone\n" ])
      entry = write!
      entry["grader_step_id"] = Step.maximum(:id) + 1_000

      expect {
        described_class.materialize!(entries: [ entry ], workspace_path: @workspace)
      }.not_to raise_error
    end
  end
end
