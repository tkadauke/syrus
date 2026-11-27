require "rails_helper"

RSpec.describe TestInsights::Subscribers do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(user: user, repository: repository) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step) { Step.create!(workflow: workflow, kind: "grader", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial") }

  describe ".on_grader_completed" do
    it "skips an empty test report without recording an operational error" do
      path = Pathname.new(Dir.mktmpdir).join("vitest-junit.xml")
      path.write("")
      allow(Syrus::Host::OperationalLogging).to receive(:ingest)
      allow(Syrus::Host::JobLog).to receive(:append!)

      described_class.on_grader_completed(
        run_id: run.id,
        grader_name: "react-tests-focused",
        junit_output_path: path.to_s,
        format_hint: "xml"
      )

      expect(Syrus::Host::OperationalLogging).not_to have_received(:ingest)
      expect(Syrus::Host::JobLog).to have_received(:append!).with(
        run: run,
        chunk: "[grader:react-tests-focused] test output is empty - skipping ingestion",
        kind: nil
      )
      expect(TestInsights::TestRun.where(run: run)).to be_empty
    ensure
      FileUtils.rm_rf(path&.dirname)
    end
  end
end
