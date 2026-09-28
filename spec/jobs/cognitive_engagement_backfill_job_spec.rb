require "rails_helper"

RSpec.describe CognitiveEngagementBackfillJob do
  it "backfills a single requested repository" do
    repository = Factories.repository
    other_repository = Factories.repository
    allow(CognitiveEngagementEvents::SourceIngestor).to receive(:call)

    described_class.perform_now(repository.id)

    expect(CognitiveEngagementEvents::SourceIngestor).to have_received(:call).with(repository: repository)
    expect(CognitiveEngagementEvents::SourceIngestor).not_to have_received(:call).with(repository: other_repository)
  end

  it "backfills all repositories when no repository is requested" do
    first = Factories.repository
    second = Factories.repository
    allow(CognitiveEngagementEvents::SourceIngestor).to receive(:call)

    described_class.perform_now

    expect(CognitiveEngagementEvents::SourceIngestor).to have_received(:call).with(repository: first)
    expect(CognitiveEngagementEvents::SourceIngestor).to have_received(:call).with(repository: second)
  end
end
