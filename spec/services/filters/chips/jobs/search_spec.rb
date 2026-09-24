require "rails_helper"

RSpec.describe Filters::Chips::Jobs::Search do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def apply(value, op: :contains)
    described_class.new(scope: Job.where(repository: repository), op: op, value: value, user: user).apply
  end

  describe "#apply" do
    it "matches on issue_title via Job.search" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 1, issue_title: "Fix the flaky deploy spec")
      expect(apply("flaky deploy")).to include(job)
    end

    it "matches on branch_name via Job.search" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 2, branch_name: "syrus/widget-repair")
      expect(apply("widget-repair")).to include(job)
    end

    it "returns no matches for an unrelated query" do
      Factories.job_record(user: user, repository: repository, issue_number: 3, issue_title: "Unrelated title")
      expect(apply("nonexistent-term-xyz")).to be_empty
    end

    it "uses the adapter-quoted LIKE escape literal in the MySQL number search branch" do
      allow(Job.connection).to receive(:adapter_name).and_return("Mysql2")
      allow(Job.connection).to receive(:quote).and_call_original
      allow(Job.connection).to receive(:quote).with("\\").and_return("'\\\\'")

      sql = apply("Investigate").to_sql

      expect(sql).to include("CAST(issue_number AS CHAR) LIKE")
      expect(sql).to include("ESCAPE '\\\\'")
    end

    it "raises for an unsupported operator" do
      Factories.job_record(user: user, repository: repository, issue_number: 4)
      expect { apply("anything", op: :equals) }.to raise_error(ArgumentError)
    end
  end

  describe "chip metadata" do
    it "registers as search in the job subject and is pinned as the free-text search field" do
      schema = Filters::Schema.for(subject: :job, user: user)
      chip = schema.find { |c| c["field"] == "search" }

      expect(chip).not_to be_nil
      expect(chip["label"]).to eq("Search")
      expect(chip["bucket"]).to eq("string")
      expect(chip["operators"]).to contain_exactly("contains")
      expect(chip["free_text_search"]).to be true
    end
  end
end
