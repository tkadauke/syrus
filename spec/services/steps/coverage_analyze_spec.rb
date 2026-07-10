require "rails_helper"
require "tmpdir"

RSpec.describe Steps::CoverageAnalyze do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) do
    Step.create!(workflow: workflow, kind: "coverage_analyze", position: 99)
  end
  let(:run) do
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind,
                      state: "running", iteration: step.iteration)
  end
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-coverage-analyze") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    # Default: no diff changes so annotations are empty
    allow(GitRunner).to receive(:new).and_return(
      instance_double(GitRunner, run: "")
    )
  end

  SAMPLE_LCOV = <<~LCOV
    TN:
    SF:app/models/user.rb
    DA:1,5
    DA:2,0
    DA:3,3
    LF:3
    LH:2
    BRF:0
    BRH:0
    FNF:1
    FNH:1
    end_of_record
  LCOV

  def write_syrus_yml(content)
    @ws_path.join(".syrus.yml").write(content)
  end

  def write_lcov(path: "coverage/lcov.info", content: SAMPLE_LCOV)
    abs = @ws_path.join(path)
    FileUtils.mkdir_p(abs.dirname)
    abs.write(content)
  end

  context "when no coverage configuration is present" do
    it "logs a skip message and returns without writing an artifact" do
      # No .syrus.yml at all
      expect { handler.call }.not_to raise_error
      expect(workflow.reload.artifact("coverage")).to be_nil
    end

    it "skips when .syrus.yml has no coverage key" do
      write_syrus_yml("grade:\n  - name: tests\n    run: bin/rspec\n")
      expect { handler.call }.not_to raise_error
      expect(workflow.reload.artifact("coverage")).to be_nil
    end
  end

  context "when coverage is configured but all artifact files are missing" do
    before do
      write_syrus_yml(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
      YAML
    end

    it "writes coverage_unavailable: true and passes" do
      expect { handler.call }.not_to raise_error
      artifact = workflow.reload.artifact("coverage")
      expect(artifact["coverage_unavailable"]).to be true
      expect(artifact["sources_status"].first).to include("found" => false)
    end
  end

  context "with a valid LCOV file" do
    before do
      write_syrus_yml(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
          hitmap_ttl_days: 1
      YAML
      write_lcov
    end

    it "writes the coverage artifact with summary, files, and sources_status" do
      handler.call

      artifact = workflow.reload.artifact("coverage")
      expect(artifact["summary"]["lines_pct"]).to eq(66.67)
      expect(artifact["files"]).to have_key("app/models/user.rb")
      expect(artifact["sources_status"].first).to include("found" => true, "artifact" => "coverage/lcov.info")
      expect(artifact["coverage_unavailable"]).to be_nil
    end

    it "creates a CoverageSnapshot" do
      expect { handler.call }.to change(CoverageSnapshot, :count).by(1)
      snapshot = CoverageSnapshot.last
      expect(snapshot.workflow).to eq(workflow)
      expect(snapshot.repository).to eq(job.repository)
      expect(snapshot.lines_pct).to be_within(0.01).of(66.67)
    end

    it "enqueues CoverageHitMapPruneJob" do
      expect {
        handler.call
      }.to have_enqueued_job(CoverageHitMapPruneJob).with(workflow.id)
    end

    it "attaches the hit map to the workflow" do
      handler.call
      expect(workflow.reload.coverage_hit_map).to be_attached
    end

    it "sets hit_map_attached: true in the artifact" do
      handler.call
      expect(workflow.reload.artifact("coverage")["hit_map_attached"]).to be true
    end
  end

  context "diff coverage annotations" do
    let(:diff_text) do
      <<~DIFF
        diff --git a/app/models/user.rb b/app/models/user.rb
        index abc..def 100644
        --- a/app/models/user.rb
        +++ b/app/models/user.rb
        @@ -0,0 +1,3 @@
        +line one
        +line two
        +line three
      DIFF
    end

    before do
      write_syrus_yml(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
      YAML
      write_lcov
      allow(GitRunner).to receive(:new).and_return(
        instance_double(GitRunner, run: diff_text)
      )
    end

    it "annotates added lines based on the hit map" do
      handler.call

      artifact = workflow.reload.artifact("coverage")
      annotations = artifact.dig("diff_annotations", "app/models/user.rb")
      expect(annotations["1"]).to eq("covered")     # DA:1,5
      expect(annotations["2"]).to eq("uncovered")   # DA:2,0
      expect(annotations["3"]).to eq("covered")     # DA:3,3
    end

    it "computes pr_delta with covered/total counts" do
      handler.call

      pr_delta = workflow.reload.artifact("coverage")["pr_delta"]
      expect(pr_delta["covered"]).to eq(2)
      expect(pr_delta["total"]).to eq(3)
      expect(pr_delta["pct"]).to be_within(0.01).of(66.67)
    end
  end

  context "threshold enforcement" do
    let(:lcov_all_uncovered) do
      <<~LCOV
        TN:
        SF:app/models/user.rb
        DA:1,0
        DA:2,0
        LF:2
        LH:0
        end_of_record
      LCOV
    end

    context "on_miss: block" do
      before do
        write_syrus_yml(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/lcov.info
                format: lcov
            threshold:
              lines: 80
            on_miss: block
        YAML
        write_lcov(content: lcov_all_uncovered)
      end

      it "raises StepFailed when lines_pct is below threshold" do
        expect { handler.call }.to raise_error(Steps::Base::StepFailed, /Coverage threshold not met/)
      end
    end

    context "on_miss: warn" do
      before do
        write_syrus_yml(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/lcov.info
                format: lcov
            threshold:
              lines: 80
            on_miss: warn
        YAML
        write_lcov(content: lcov_all_uncovered)
      end

      it "passes but sets threshold_miss: true in the artifact" do
        expect { handler.call }.not_to raise_error
        artifact = workflow.reload.artifact("coverage")
        expect(artifact["threshold_miss"]).to be true
        expect(artifact["threshold_miss_details"]["lines_pct"]).to eq(0.0)
        expect(artifact["threshold_miss_details"]["threshold_lines"]).to eq(80.0)
      end
    end

    context "on_miss: schedule" do
      before do
        write_syrus_yml(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/lcov.info
                format: lcov
            threshold:
              lines: 80
            on_miss: schedule
        YAML
        write_lcov(content: lcov_all_uncovered)
      end

      it "passes and enqueues CoverageScheduleTriggerJob" do
        expect { handler.call }.not_to raise_error
        expect(CoverageScheduleTriggerJob).to have_been_enqueued.with(workflow.id)
      end
    end

    context "when coverage meets the threshold" do
      before do
        write_syrus_yml(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/lcov.info
                format: lcov
            threshold:
              lines: 50
            on_miss: block
        YAML
        write_lcov  # 66.67% coverage
      end

      it "passes without raising" do
        expect { handler.call }.not_to raise_error
        expect(workflow.reload.artifact("coverage")["threshold_miss"]).to be_nil
      end
    end
  end
end
