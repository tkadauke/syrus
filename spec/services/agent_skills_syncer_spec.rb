require "rails_helper"
require "tmpdir"

RSpec.describe AgentSkillsSyncer do
  let(:tmp_dst) { Pathname.new(Dir.mktmpdir("syncer-dst")) }

  after { FileUtils.rm_rf(tmp_dst) }

  describe ".sync" do
    it "copies each lib/agent_skills/*.md to <dst>/<id>/SKILL.md" do
      described_class.sync(dst: tmp_dst)
      skill_ids = Dir.glob(Rails.root.join("lib/agent_skills/*.md")).map { |f| File.basename(f, ".md") }
      skill_ids.each do |id|
        expect(tmp_dst.join("#{id}/SKILL.md")).to exist, "expected skill file at #{tmp_dst.join("#{id}/SKILL.md")}"
      end
    end

    it "creates the destination directory when it does not exist" do
      nested = tmp_dst.join("new/nested/skills")
      described_class.sync(dst: nested)
      expect(nested).to exist
    end

    it "overwrites stale SKILL.md files on re-sync" do
      described_class.sync(dst: tmp_dst)
      skill_id = Dir.glob(Rails.root.join("lib/agent_skills/*.md")).map { |f| File.basename(f, ".md") }.first
      stale_path = tmp_dst.join("#{skill_id}/SKILL.md")
      stale_path.write("stale content")

      described_class.sync(dst: tmp_dst)

      expect(stale_path.read).not_to eq("stale content")
    end

    it "is a no-op when lib/agent_skills/ does not exist" do
      allow(Rails).to receive(:root).and_return(Pathname.new(Dir.mktmpdir))
      expect { described_class.sync(dst: tmp_dst) }.not_to raise_error
    end

    it "is a no-op when lib/agent_skills/ is empty" do
      empty_root = Pathname.new(Dir.mktmpdir)
      FileUtils.mkdir_p(empty_root.join("lib/agent_skills"))
      allow(Rails).to receive(:root).and_return(empty_root)
      expect { described_class.sync(dst: tmp_dst) }.not_to raise_error
    end
  end
end
