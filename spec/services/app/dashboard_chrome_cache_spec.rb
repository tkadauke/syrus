require "rails_helper"

RSpec.describe App::DashboardChromeCache do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache_store) }

  it "does not break model commits when the cache store is unavailable" do
    allow(Rails.cache).to receive(:write).and_raise(ActiveRecord::StatementInvalid, "cache schema is unavailable")
    allow(Rails.logger).to receive(:warn)

    expect { described_class.invalidate_all! }.not_to raise_error
    expect { described_class.invalidate_user!(123) }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).twice.with(/Dashboard chrome cache invalidation skipped/)
  end

  it "isolates count revisions by repository and subject while sharing visibility revisions with chrome" do
    user = Factories.user
    other_user = Factories.user

    initial = described_class.count_revision_for(user: user, repository_ids: [ 11 ], subject: "job")
    described_class.invalidate_counts!(11, subjects: %w[job workflow])

    expect(described_class.count_revision_for(user: user, repository_ids: [ 11 ], subject: "job")).not_to eq(initial)
    expect(described_class.count_revision_for(user: user, repository_ids: [ 11 ], subject: "workflow")).not_to eq(initial)
    expect(described_class.count_revision_for(user: user, repository_ids: [ 12 ], subject: "job")).to eq(initial)
    expect(described_class.count_revision_for(user: other_user, repository_ids: [ 11 ], subject: "job").last).to eq(
      described_class.count_revision_for(user: user, repository_ids: [ 11 ], subject: "job").last
    )

    other_before = described_class.count_revision_for(user: other_user, repository_ids: [ 11 ], subject: "job")
    described_class.invalidate_user!(user)

    expect(described_class.count_revision_for(user: user, repository_ids: [ 11 ], subject: "job")).not_to eq(other_before)
    expect(described_class.count_revision_for(user: other_user, repository_ids: [ 11 ], subject: "job")).to eq(other_before)
  end
end
