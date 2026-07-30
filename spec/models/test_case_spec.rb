require "rails_helper"

RSpec.describe TestCase do
  let(:job)      { Factories.job }
  let(:run)      { job.initial_run }
  let(:repo)     { job.repository }
  let(:test_run) do
    TestRun.create!(run: run, repository: repo, grader_name: "rspec",
                    total_count: 1, passed_count: 1, failed_count: 0,
                    skipped_count: 0, error_count: 0)
  end

  def build_case(**attrs)
    TestCase.new(
      { test_run: test_run, repository: repo,
        name: "it does the thing", suite_name: "MySpec", status: "passed" }.merge(attrs)
    )
  end

  it "is valid with required attributes" do
    expect(build_case).to be_valid
  end

  it "requires name" do
    expect(build_case(name: nil)).not_to be_valid
  end

  it "requires suite_name" do
    expect(build_case(suite_name: nil)).not_to be_valid
  end

  it "requires a valid status" do
    expect(build_case(status: "pending")).not_to be_valid
  end

  it "accepts all valid statuses" do
    TestCase::STATUSES.each do |s|
      expect(build_case(status: s)).to be_valid, "expected #{s} to be valid"
    end
  end

  it "accepts nil duration_ms" do
    expect(build_case(duration_ms: nil)).to be_valid
  end

  it "rejects negative duration_ms" do
    expect(build_case(duration_ms: -1)).not_to be_valid
  end

  it "accepts nil file_path, output, failure_message, failure_backtrace" do
    expect(build_case(file_path: nil, output: nil, failure_message: nil, failure_backtrace: nil)).to be_valid
  end

  describe "scopes" do
    before do
      TestCase::STATUSES.each do |s|
        test_run.test_cases.create!(repository: repo, name: "case #{s}", suite_name: "S", status: s)
      end
    end

    it "scopes .passed" do
      expect(TestCase.passed.pluck(:status).uniq).to eq([ "passed" ])
    end

    it "scopes .failed" do
      expect(TestCase.failed.pluck(:status).uniq).to eq([ "failed" ])
    end

    it "scopes .skipped" do
      expect(TestCase.skipped.pluck(:status).uniq).to eq([ "skipped" ])
    end

    it "scopes .errored" do
      expect(TestCase.errored.pluck(:status).uniq).to eq([ "error" ])
    end
  end
end
