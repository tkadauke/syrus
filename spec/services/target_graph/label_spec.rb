require "rails_helper"

RSpec.describe TargetGraph::Label do
  describe ".parse" do
    it "parses the repository root label" do
      label = described_class.parse("//:repo")
      expect(label.project_path).to eq("")
      expect(label.target_name).to eq("repo")
      expect(label.root_project?).to be(true)
      expect(label.to_s).to eq("//:repo")
    end

    it "parses a nested project's default label" do
      label = described_class.parse("//cli:default")
      expect(label.project_path).to eq("cli")
      expect(label.target_name).to eq("default")
      expect(label.root_project?).to be(false)
    end

    it "parses a namespaced generated target label" do
      label = described_class.parse("//cli:grade/tests")
      expect(label.project_path).to eq("cli")
      expect(label.target_name).to eq("grade/tests")
      expect(label.target_segments).to eq(%w[grade tests])
    end

    it "parses a nested project path with a namespaced target" do
      label = described_class.parse("//desktop:build/package")
      expect(label.project_path).to eq("desktop")
      expect(label.target_name).to eq("build/package")
    end

    it "parses a multi-segment project path" do
      label = described_class.parse("//apps/ios:default")
      expect(label.project_path).to eq("apps/ios")
      expect(label.project_segments).to eq(%w[apps ios])
      expect(label.target_name).to eq("default")
    end

    it "trims surrounding whitespace" do
      label = described_class.parse("  //cli:default  ")
      expect(label.to_s).to eq("//cli:default")
    end

    it "round-trips through to_s" do
      %w[//:repo //cli:default //cli:grade/tests //desktop:build/package //apps/ios:default].each do |raw|
        expect(described_class.parse(raw).to_s).to eq(raw)
      end
    end

    it "raises for a string missing the leading //" do
      expect { described_class.parse("cli:default") }.to raise_error(described_class::ParseError, /expected/)
    end

    it "raises for a string missing the : separator" do
      expect { described_class.parse("//cli") }.to raise_error(described_class::ParseError)
    end

    it "raises for a blank target name" do
      expect { described_class.parse("//cli:") }.to raise_error(described_class::ParseError)
    end

    it "raises for an empty path segment from a double slash" do
      expect { described_class.parse("//cli//sub:default") }.to raise_error(described_class::ParseError, /project_path segment/)
    end

    it "raises for an empty target segment from a double slash" do
      expect { described_class.parse("//cli:grade//tests") }.to raise_error(described_class::ParseError, /target_name segment/)
    end

    it "raises for a target segment with invalid characters" do
      expect { described_class.parse("//cli:grade tests") }.to raise_error(described_class::ParseError)
    end

    it "raises for a project segment with invalid characters" do
      expect { described_class.parse("//cli$:default") }.to raise_error(described_class::ParseError)
    end
  end

  describe ".coerce" do
    it "returns an existing Label unchanged" do
      label = described_class.parse("//cli:default")
      expect(described_class.coerce(label)).to be(label)
    end

    it "parses a raw string" do
      expect(described_class.coerce("//cli:default")).to eq(described_class.parse("//cli:default"))
    end
  end

  describe ".root" do
    it "builds the canonical repository root label" do
      expect(described_class.root.to_s).to eq("//:repo")
    end
  end

  describe ".default_for" do
    it "builds a project's implicit default-target label" do
      expect(described_class.default_for("cli").to_s).to eq("//cli:default")
    end

    it "builds the root default label for a blank project path" do
      expect(described_class.default_for("").to_s).to eq("//:default")
    end
  end

  describe "#project_default_label" do
    it "returns the repo root label for a root-scoped label" do
      label = described_class.parse("//:grade/rspec")
      expect(label.project_default_label.to_s).to eq("//:repo")
    end

    it "returns the project's default label for a nested label" do
      label = described_class.parse("//cli:grade/tests")
      expect(label.project_default_label.to_s).to eq("//cli:default")
    end
  end

  describe "equality and hashing" do
    it "treats labels built from the same canonical string as equal" do
      a = described_class.parse("//cli:default")
      b = described_class.new(project_path: "cli", target_name: "default")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "is usable as a Hash key" do
      a = described_class.parse("//cli:default")
      b = described_class.parse("//cli:default")
      index = { a => "value" }
      expect(index[b]).to eq("value")
    end

    it "treats labels with different target names as distinct" do
      expect(described_class.parse("//cli:default")).not_to eq(described_class.parse("//cli:grade/tests"))
    end
  end
end
