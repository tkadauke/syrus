require "rails_helper"

RSpec.describe InsightScheduleConfig do
  let(:repository) { Factories.repository }

  def build_config(**attrs)
    InsightScheduleConfig.new({ repository: repository }.merge(attrs))
  end

  it "is valid with defaults" do
    config = build_config
    expect(config).to be_valid
  end

  it "defaults enabled to false" do
    expect(build_config.enabled).to be false
  end

  it "defaults min_jobs_since_last_run to 5" do
    expect(build_config.min_jobs_since_last_run).to eq(5)
  end

  it "defaults max_jobs_since_last_run to 10" do
    expect(build_config.max_jobs_since_last_run).to eq(10)
  end

  describe "min_jobs_since_last_run validation" do
    it "requires at least 1" do
      expect(build_config(min_jobs_since_last_run: 0)).not_to be_valid
    end

    it "rejects negative values" do
      expect(build_config(min_jobs_since_last_run: -1)).not_to be_valid
    end

    it "accepts 1" do
      expect(build_config(min_jobs_since_last_run: 1, max_jobs_since_last_run: 2)).to be_valid
    end
  end

  describe "max_jobs_since_last_run validation" do
    it "requires at least 1" do
      expect(build_config(max_jobs_since_last_run: 0)).not_to be_valid
    end

    it "rejects negative values" do
      expect(build_config(max_jobs_since_last_run: -1)).not_to be_valid
    end
  end

  describe "min < max validation" do
    it "is invalid when min equals max" do
      config = build_config(min_jobs_since_last_run: 5, max_jobs_since_last_run: 5)
      expect(config).not_to be_valid
      expect(config.errors[:min_jobs_since_last_run]).to include("must be less than max_jobs_since_last_run")
    end

    it "is invalid when min exceeds max" do
      config = build_config(min_jobs_since_last_run: 10, max_jobs_since_last_run: 5)
      expect(config).not_to be_valid
      expect(config.errors[:min_jobs_since_last_run]).to include("must be less than max_jobs_since_last_run")
    end

    it "is valid when min is strictly less than max" do
      expect(build_config(min_jobs_since_last_run: 3, max_jobs_since_last_run: 7)).to be_valid
    end
  end
end
