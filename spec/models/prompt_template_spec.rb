require "rails_helper"

RSpec.describe PromptTemplate do
  describe ".all" do
    it "returns a non-empty list" do
      expect(described_class.all).not_to be_empty
    end

    it "every template has a non-blank id, name, description, and prompt" do
      described_class.all.each do |t|
        expect(t.id).to        be_present, "template #{t.inspect} missing id"
        expect(t.name).to      be_present, "template #{t.id} missing name"
        expect(t.description).to be_present, "template #{t.id} missing description"
        expect(t.prompt).to    be_present, "template #{t.id} missing prompt"
      end
    end

    it "ids are unique" do
      ids = described_class.all.map(&:id)
      expect(ids.uniq).to eq(ids)
    end
  end

  describe ".find" do
    it "returns the matching template by id" do
      first = described_class.all.first
      expect(described_class.find(first.id)).to eq(first)
    end

    it "returns nil for an unknown id" do
      expect(described_class.find("no-such-template")).to be_nil
    end
  end

  describe "configure-syrus-prep template" do
    subject(:template) { described_class.find("configure-syrus-prep") }

    it "exists" do
      expect(template).to be_present
    end

    it "prompt covers common package managers" do
      expect(template.prompt).to include("Gemfile")
      expect(template.prompt).to include("package.json")
      expect(template.prompt).to include(".syrus.yml")
    end
  end

  describe "add-github-actions-ci template" do
    subject(:template) { described_class.find("add-github-actions-ci") }

    it "exists" do
      expect(template).to be_present
    end

    it "prompt mentions GitHub Actions" do
      expect(template.prompt).to include("GitHub Actions")
    end
  end

  describe "update-dependencies template" do
    subject(:template) { described_class.find("update-dependencies") }

    it "exists" do
      expect(template).to be_present
    end

    it "prompt mentions lockfile" do
      expect(template.prompt).to include("lockfile")
    end
  end
end
