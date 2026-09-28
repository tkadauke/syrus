require "rails_helper"

RSpec.describe CodeFacts::PathNormalizer do
  describe ".normalize" do
    it "normalizes absolute workspace paths the same way coverage hit maps do" do
      expect(
        described_class.normalize(
          "/work/repo/packages/web/src/App.tsx",
          workspace_path: "/work/repo",
          base_path: "packages/web"
        )
      ).to eq("packages/web/src/App.tsx")
    end

    it "treats stripped workspace paths as repository-root relative" do
      expect(
        described_class.normalize(
          "/work/repo/src/App.tsx",
          workspace_path: "/work/repo",
          base_path: "packages/web"
        )
      ).to eq("src/App.tsx")
    end

    it "scopes relative coverage paths under the configured base path" do
      expect(
        described_class.normalize(
          "./src/App.tsx",
          workspace_path: "/work/repo",
          base_path: "packages/web"
        )
      ).to eq("packages/web/src/App.tsx")
    end

    it "does not duplicate a base path that is already present" do
      expect(
        described_class.normalize("packages/web/src/App.tsx", base_path: "packages/web")
      ).to eq("packages/web/src/App.tsx")
    end
  end
end
