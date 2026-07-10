require "rails_helper"

RSpec.describe SyrusMcp::ReportMainConcernTool do
  include ActiveJob::TestHelper

  let(:run) { Factories.job.initial_run }
  let(:repository) { run.job.repository }

  before { AppSetting.current.update!(main_concern_report_threshold: 2) }

  def call(reason: "Tests in files I did not touch are failing", failing_tests: nil)
    described_class.call(reason: reason, failing_tests: failing_tests, server_context: { run: run })
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("report_main_concern")
    expect(described_class.input_schema_value.to_h[:required]).to eq(%w[reason])
  end

  it "creates a MainConcernReport with the provided reason" do
    expect { call }.to change { MainConcernReport.count }.by(1)

    report = MainConcernReport.last
    expect(report).to have_attributes(
      repository: repository,
      job: run.job,
      workflow: run.workflow,
      run: run,
      reason: "Tests in files I did not touch are failing"
    )
  end

  it "stores failing_tests when provided" do
    call(failing_tests: [ "spec/foo_spec.rb", "spec/bar_spec.rb" ])

    expect(MainConcernReport.last.failing_tests).to eq([ "spec/foo_spec.rb", "spec/bar_spec.rb" ])
  end

  it "stores nil failing_tests when not provided" do
    call

    expect(MainConcernReport.last.failing_tests).to be_nil
  end

  it "returns a success response" do
    response = call
    expect(response).not_to be_error
    expect(response.content.first[:text]).to include("Reported")
  end

  it "rejects an empty reason" do
    response = call(reason: "  ")
    expect(response).to be_error
    expect(response.content.first[:text]).to include("reason is required")
  end

  it "writes a JobLog audit line" do
    expect { call }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] report_main_concern")
  end

  it "invokes MainConcernAggregator.check! with the repository" do
    expect(MainConcernAggregator).to receive(:check!).with(repository)
    call
  end

  it "normalizes binary-tagged UTF-8 in reason" do
    call(reason: "Tests failing in unrelated files".b)

    report = MainConcernReport.last
    expect(report.reason).to eq("Tests failing in unrelated files")
    expect(report.reason.encoding).to eq(Encoding::UTF_8)
  end

  it "accepts a run_id-only sidecar context" do
    expect {
      described_class.call(
        reason: "unrelated failures",
        server_context: { run_id: run.id }
      )
    }.to change { MainConcernReport.count }.by(1)
  end

  context "when aggregator reaches threshold" do
    it "triggers broken-main detection" do
      other_job = Factories.job(repository: repository)
      other_run = other_job.initial_run
      MainConcernReport.create!(
        repository: repository, job: other_job,
        workflow: other_run.workflow, run: other_run,
        reason: "also failing"
      )

      expect {
        call
      }.to change { repository.reload.landing_paused }.to(true)
    end
  end
end
