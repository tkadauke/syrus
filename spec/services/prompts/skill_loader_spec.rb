require "rails_helper"

RSpec.describe Prompts::SkillLoader do
  describe ".render" do
    let(:skill_content) do
      <<~MD
        ---
        name: test
        description: A test skill
        ---

        Hello $ARGUMENTS world
      MD
    end

    before { allow(File).to receive(:read).and_return(skill_content) }

    it "strips YAML frontmatter and substitutes $ARGUMENTS" do
      result = described_class.render("/fake/skill.md", "beautiful")
      expect(result).to eq("Hello beautiful world")
    end

    it "strips leading and trailing whitespace from the rendered body" do
      allow(File).to receive(:read).and_return("---\nname: t\n---\n\n  $ARGUMENTS  ")
      expect(described_class.render("/fake/skill.md", "x")).to eq("x")
    end

    it "leaves content intact when there is no frontmatter" do
      allow(File).to receive(:read).and_return("Do $ARGUMENTS things")
      expect(described_class.render("/fake/skill.md", "cool")).to eq("Do cool things")
    end

    it "propagates Errno::ENOENT when the skill file does not exist" do
      allow(File).to receive(:read).and_call_original
      expect {
        described_class.render("/nonexistent/skill.md", "args")
      }.to raise_error(Errno::ENOENT)
    end
  end
end
