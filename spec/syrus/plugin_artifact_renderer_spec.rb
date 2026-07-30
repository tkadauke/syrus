require "rails_helper"

RSpec.describe "SyrusRails artifact renderers" do
  describe SyrusRails::SchemaErdRenderer do
    it "declares the expected artifact_type" do
      expect(described_class.artifact_type).to eq("rails_schema_erd")
    end

    it "declares the expected renderer_type" do
      expect(described_class.renderer_type).to eq(:erd_diagram)
    end

    it "extends Syrus::Plugin::ArtifactRenderer" do
      expect(described_class.singleton_class.ancestors).to include(Syrus::Plugin::ArtifactRenderer)
    end
  end

  describe SyrusRails::MigrationDiffRenderer do
    it "declares the expected artifact_type" do
      expect(described_class.artifact_type).to eq("rails_migration_diff")
    end

    it "declares the expected renderer_type" do
      expect(described_class.renderer_type).to eq(:migration_diff)
    end

    it "extends Syrus::Plugin::ArtifactRenderer" do
      expect(described_class.singleton_class.ancestors).to include(Syrus::Plugin::ArtifactRenderer)
    end
  end

  describe Syrus::Plugin::ArtifactRenderer do
    it "raises NotImplementedError on artifact_type when not overridden" do
      klass = Class.new { extend Syrus::Plugin::ArtifactRenderer }
      expect { klass.artifact_type }.to raise_error(NotImplementedError)
    end

    it "raises NotImplementedError on renderer_type when not overridden" do
      klass = Class.new { extend Syrus::Plugin::ArtifactRenderer }
      expect { klass.renderer_type }.to raise_error(NotImplementedError)
    end
  end
end
