require "rails_helper"

RSpec.describe BuildCache::RepositorySettings do
  let(:repository) { Factories.repository }

  describe ".for_repository" do
    it "returns nil when no row exists" do
      expect(described_class.for_repository(repository)).to be_nil
    end

    it "finds the row for a repository instance" do
      settings = described_class.create!(repository: repository, basedirs_safe: true)

      expect(described_class.for_repository(repository)).to eq(settings)
    end

    it "finds the row for a raw repository id" do
      settings = described_class.create!(repository: repository, basedirs_safe: true)

      expect(described_class.for_repository(repository.id)).to eq(settings)
    end
  end

  describe ".basedirs_safe_for?" do
    it "is false when no row exists (the default, safe behavior)" do
      expect(described_class.basedirs_safe_for?(repository)).to be false
    end

    it "is true when the repository opted in" do
      described_class.create!(repository: repository, basedirs_safe: true)

      expect(described_class.basedirs_safe_for?(repository)).to be true
    end
  end

  it "enforces one settings row per repository" do
    described_class.create!(repository: repository, basedirs_safe: true)

    expect { described_class.create!(repository: repository, basedirs_safe: false) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
