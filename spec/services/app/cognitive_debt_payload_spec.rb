require "rails_helper"

RSpec.describe App::CognitiveDebtPayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 91) }

  def diff_version(path:, created_at:)
    @version_index = @version_index.to_i + 1
    DiffReviewVersion.create!(
      job: job,
      version_index: @version_index,
      base_sha: "base#{@version_index}",
      head_sha: "head#{@version_index}",
      source_key: "spec-#{@version_index}",
      files_snapshot: [ { "path" => path, "status" => "modified" } ],
      created_at: created_at
    )
  end

  describe "#latest_diff_version_time_by_path" do
    # Regression: this used `ORDER BY created_at DESC` while plucking
    # `files_snapshot`, so MySQL sorted every row in the repository carrying a
    # ~25KB JSON blob. At production scale that was ~91MB of sort payload and
    # the repository page 500'd with "Out of sort memory". The result must stay
    # identical without asking the database to sort.
    it "keeps the newest timestamp per path" do
      old = 10.days.ago.change(usec: 0)
      recent = 1.day.ago.change(usec: 0)
      diff_version(path: "app/a.rb", created_at: old)
      diff_version(path: "app/a.rb", created_at: recent)
      diff_version(path: "app/b.rb", created_at: old)

      times = described_class.new(repository: repository).send(:latest_diff_version_time_by_path)

      expect(times["app/a.rb"]).to be_within(1.second).of(recent)
      expect(times["app/b.rb"]).to be_within(1.second).of(old)
    end

    it "issues no sorted query over the snapshot column" do
      diff_version(path: "app/a.rb", created_at: 1.day.ago)
      sorted = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        sorted << sql if sql.include?("files_snapshot") && sql.include?("ORDER BY") && sql.include?("created_at")
      end

      described_class.new(repository: repository).send(:latest_diff_version_time_by_path)

      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(sorted).to be_empty
    end

    it "spans more rows than a single batch" do
      stub_const("App::CognitiveDebtPayload::DIFF_VERSION_BATCH_SIZE", 2)
      5.times { |i| diff_version(path: "app/f#{i}.rb", created_at: (10 - i).days.ago) }

      times = described_class.new(repository: repository).send(:latest_diff_version_time_by_path)

      expect(times.keys).to match_array((0..4).map { |i| "app/f#{i}.rb" })
    end
  end
end
