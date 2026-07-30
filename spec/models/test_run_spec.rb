require "rails_helper"

RSpec.describe TestRun do
  let(:job)  { Factories.job }
  let(:run)  { job.initial_run }
  let(:repo) { job.repository }

  def build_test_run(**attrs)
    TestRun.new(
      { run: run, repository: repo, grader_name: "rspec", total_count: 3,
        passed_count: 2, failed_count: 1, skipped_count: 0, error_count: 0 }.merge(attrs)
    )
  end

  it "is valid with required attributes" do
    expect(build_test_run).to be_valid
  end

  it "requires grader_name" do
    expect(build_test_run(grader_name: nil)).not_to be_valid
  end

  it "requires grader_name to be at most 128 characters" do
    expect(build_test_run(grader_name: "a" * 129)).not_to be_valid
  end

  it "requires non-negative counts" do
    %i[total_count passed_count failed_count skipped_count error_count].each do |col|
      expect(build_test_run(col => -1)).not_to be_valid
    end
  end

  it "requires integer counts" do
    expect(build_test_run(total_count: 1.5)).not_to be_valid
  end

  it "accepts nil duration_ms" do
    expect(build_test_run(duration_ms: nil)).to be_valid
  end

  it "rejects negative duration_ms" do
    expect(build_test_run(duration_ms: -1)).not_to be_valid
  end

  it "belongs to run and repository" do
    tr = build_test_run.tap(&:save!)
    expect(tr.run).to eq(run)
    expect(tr.repository).to eq(repo)
  end

  it "destroys test_cases on destroy" do
    tr = build_test_run.tap(&:save!)
    tr.test_cases.create!(
      repository: repo, name: "it works", suite_name: "MySpec",
      status: "passed"
    )
    expect { tr.destroy! }.to change(TestCase, :count).by(-1)
  end
end
