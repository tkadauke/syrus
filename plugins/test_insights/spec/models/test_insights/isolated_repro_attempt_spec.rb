require "rails_helper"

RSpec.describe TestInsights::IsolatedReproAttempt do
  let(:job)  { Factories.job }
  let(:repo) { job.repository }

  def create_attempt(**attrs)
    described_class.create!(
      {
        repository: repo,
        grader_name: "rspec",
        suite_name: "spec/foo_spec.rb",
        name: "does the thing",
        sha: "c" * 40,
        reproduced: false,
        command: "bundle exec rspec",
        output: "ok"
      }.merge(attrs)
    )
  end

  it "requires grader_name, suite_name, name, and sha" do
    attempt = described_class.new(repository: repo, reproduced: false)

    expect(attempt).not_to be_valid
    expect(attempt.errors.attribute_names).to include(:grader_name, :suite_name, :name, :sha)
  end

  describe ".truncate_command / .truncate_output" do
    it "truncates overlong values to their byte cap, for callers to apply before writing" do
      expect(described_class.truncate_command("x" * (described_class::MAX_COMMAND_BYTES + 100)).bytesize)
        .to eq(described_class::MAX_COMMAND_BYTES)
      expect(described_class.truncate_output("y" * (described_class::MAX_TEXT_BYTES + 100)).bytesize)
        .to eq(described_class::MAX_TEXT_BYTES)
    end

    it "returns nil for nil input" do
      expect(described_class.truncate_command(nil)).to be_nil
      expect(described_class.truncate_output(nil)).to be_nil
    end
  end

  describe ".for_lookup" do
    it "scopes to the exact repository, suite_name, name, and sha" do
      match = create_attempt
      create_attempt(sha: "d" * 40)
      create_attempt(name: "a different example")

      expect(described_class.for_lookup(repository: repo, suite_name: "spec/foo_spec.rb", name: "does the thing", sha: "c" * 40)).to contain_exactly(match)
    end
  end

  describe ".prunable" do
    it "includes only rows older than RETAIN_AFTER" do
      old = create_attempt
      old.update_columns(created_at: (described_class::RETAIN_AFTER + 1.day).ago)
      fresh = create_attempt(name: "a fresh one")

      expect(described_class.prunable).to contain_exactly(old)
      expect(described_class.prunable).not_to include(fresh)
    end
  end
end
