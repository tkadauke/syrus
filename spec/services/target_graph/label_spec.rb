require "rails_helper"

RSpec.describe TargetGraph::Label do
  describe ".parse" do
    it "parses the repo root label" do
      label = described_class.parse("//:repo")

      expect(label.package).to eq("")
      expect(label.name).to eq("repo")
      expect(label).to be_root
      expect(label.to_s).to eq("//:repo")
    end

    it "parses a package-scoped default label" do
      label = described_class.parse("//cli:default")

      expect(label.package).to eq("cli")
      expect(label.name).to eq("default")
      expect(label).not_to be_root
    end

    it "parses multi-segment names" do
      label = described_class.parse("//cli:grade/tests")

      expect(label.package).to eq("cli")
      expect(label.name).to eq("grade/tests")
      expect(label.name_segments).to eq(%w[grade tests])
    end

    it "parses multi-segment packages and names" do
      label = described_class.parse("//desktop:build/package")

      expect(label.package).to eq("desktop")
      expect(label.name).to eq("build/package")
    end

    it "parses nested packages" do
      label = described_class.parse("//apps/ios:default")

      expect(label.package).to eq("apps/ios")
      expect(label.package_segments).to eq(%w[apps ios])
    end

    it "canonicalizes back to the same string" do
      %w[//:repo //cli:default //cli:grade/tests //desktop:build/package //apps/ios:default].each do |raw|
        expect(described_class.parse(raw).to_s).to eq(raw)
      end
    end

    it "rejects strings without the // prefix" do
      expect { described_class.parse("cli:default") }.to raise_error(TargetGraph::Label::ParseError)
    end

    it "rejects strings without a :name part" do
      expect { described_class.parse("//cli") }.to raise_error(TargetGraph::Label::ParseError)
    end

    it "rejects invalid characters in package segments" do
      expect { described_class.parse("//cli!:default") }.to raise_error(TargetGraph::Label::ParseError)
    end

    it "rejects invalid characters in name segments" do
      expect { described_class.parse("//cli:grade tests") }.to raise_error(TargetGraph::Label::ParseError)
    end

    it "rejects a blank name" do
      expect { described_class.parse("//cli:") }.to raise_error(TargetGraph::Label::ParseError)
    end

    it "rejects doubled slashes within a segment" do
      expect { described_class.parse("//cli//sub:default") }.to raise_error(TargetGraph::Label::ParseError)
    end

    it "rejects leading/trailing slashes within a segment" do
      expect { described_class.parse("//cli:/default") }.to raise_error(TargetGraph::Label::ParseError)
      expect { described_class.parse("//cli:default/") }.to raise_error(TargetGraph::Label::ParseError)
    end
  end

  describe ".resolve" do
    it "parses absolute references as-is" do
      label = described_class.resolve("//desktop:renderer", package: "cli")

      expect(label.to_s).to eq("//desktop:renderer")
    end

    it "resolves a relative :name reference against the given package" do
      label = described_class.resolve(":renderer", package: "desktop")

      expect(label.to_s).to eq("//desktop:renderer")
    end

    it "resolves a relative reference against the root package" do
      label = described_class.resolve(":repo", package: "")

      expect(label.to_s).to eq("//:repo")
    end

    it "rejects a bare name with neither // nor : prefix" do
      expect { described_class.resolve("renderer", package: "desktop") }.to raise_error(TargetGraph::Label::ParseError)
    end
  end

  describe ".root" do
    it "builds a root-package label" do
      label = described_class.root("repo")

      expect(label.to_s).to eq("//:repo")
      expect(label).to be_root
    end
  end

  describe "equality and hashing" do
    it "considers two labels with the same canonical string equal" do
      a = described_class.parse("//cli:default")
      b = described_class.new(package: "cli", name: "default")

      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "can be used as a Hash key" do
      map = { described_class.parse("//cli:default") => :cli }

      expect(map[described_class.new(package: "cli", name: "default")]).to eq(:cli)
    end
  end
end
