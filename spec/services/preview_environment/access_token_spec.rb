require "rails_helper"

RSpec.describe PreviewEnvironment::AccessToken do
  let(:preview_environment) { PreviewEnvironment.create!(job: Factories.job, workspace_path: "/tmp/workspace") }

  describe ".issue" do
    it "issues a token that resolves to the preview environment id" do
      token = described_class.issue(preview_environment)

      expect(described_class.preview_environment_id_for(token)).to eq(preview_environment.id)
    end

    it "returns nil for invalid tokens" do
      expect(described_class.preview_environment_id_for("not-a-token")).to be_nil
    end

    it "returns nil for expired tokens" do
      freeze_time { @token = described_class.issue(preview_environment) }

      travel(described_class::TTL + 1.minute) do
        expect(described_class.preview_environment_id_for(@token)).to be_nil
      end
    end
  end
end
