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

  shared_examples "a skill-backed template" do |skill_id|
    let(:skill_path) { Rails.root.join("lib/agent_skills/#{skill_id}.md") }

    it "has a matching skill file in lib/agent_skills/" do
      expect(skill_path).to exist
    end

    it "prompt contains the skill body with frontmatter stripped" do
      raw      = skill_path.read
      expected = raw.sub(/\A---\n.*?\n---\n/m, "").strip
      expect(subject.prompt).to eq(expected)
    end

    it "prompt does not contain YAML frontmatter" do
      expect(subject.prompt).not_to start_with("---")
    end

    it "prompt is non-blank" do
      expect(subject.prompt).to be_present
    end
  end

  describe "configure-syrus-prep template" do
    subject(:template) { described_class.find("configure-syrus-prep") }

    it "exists" do
      expect(template).to be_present
    end

    include_examples "a skill-backed template", "configure-syrus-prep"
  end

  describe "add-github-actions-ci template" do
    subject(:template) { described_class.find("add-github-actions-ci") }

    it "exists" do
      expect(template).to be_present
    end

    include_examples "a skill-backed template", "add-github-actions-ci"
  end

  describe "update-dependencies template" do
    subject(:template) { described_class.find("update-dependencies") }

    it "exists" do
      expect(template).to be_present
    end

    include_examples "a skill-backed template", "update-dependencies"
  end
end
