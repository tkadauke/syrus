require "rails_helper"

RSpec.describe TargetGraph::Project do
  describe "#initialize" do
    it "defaults label to the id and path to the repo root" do
      project = described_class.new(id: "repo")

      expect(project.label).to eq("repo")
      expect(project.path).to eq("")
      expect(project).to be_root
      expect(project.kind).to be_nil
      expect(project.owner_config_path).to be_nil
    end

    it "accepts an explicit label, kind, and nested path" do
      project = described_class.new(id: "desktop", label: "Desktop App", kind: "desktop_app", path: "desktop", owner_config_path: "desktop/.syrus.yml")

      expect(project.label).to eq("Desktop App")
      expect(project.kind).to eq("desktop_app")
      expect(project.path).to eq("desktop")
      expect(project).not_to be_root
      expect(project.owner_config_path).to eq("desktop/.syrus.yml")
    end

    it "rejects a blank id" do
      expect { described_class.new(id: "") }.to raise_error(ArgumentError)
    end

    it "rejects an id with invalid characters" do
      expect { described_class.new(id: "desktop app") }.to raise_error(ArgumentError)
    end

    it "rejects a path with a leading slash" do
      expect { described_class.new(id: "desktop", path: "/desktop") }.to raise_error(ArgumentError)
    end

    it "rejects a path with a trailing slash" do
      expect { described_class.new(id: "desktop", path: "desktop/") }.to raise_error(ArgumentError)
    end
  end
end
