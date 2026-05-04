require "fileutils"

# Copies Syrus's built-in agent skills from lib/agent_skills/ to ~/.claude/skills/
# so they are available to all claude sessions on this host, not just within
# Syrus-managed workspaces.
#
# Each lib/agent_skills/<id>.md becomes ~/.claude/skills/<id>/SKILL.md — the
# layout Claude Code expects for user-global skills.
#
# Accepts an optional +dst+ so tests can redirect the copy to a temp directory
# without touching the real ~/.claude directory.
class AgentSkillsSyncer
  def self.sync(dst: nil)
    new(dst: dst).sync
  end

  def initialize(dst: nil)
    @dst = dst
  end

  def sync
    skills_src = Rails.root.join("lib/agent_skills")
    return unless skills_src.exist?

    skill_files = Dir.glob(skills_src.join("*.md"))
    return if skill_files.empty?

    skills_dst = @dst || Pathname.new(File.expand_path("~/.claude/skills"))
    FileUtils.mkdir_p(skills_dst)

    skill_files.each do |skill_file|
      skill_id  = File.basename(skill_file, ".md")
      skill_dir = skills_dst.join(skill_id)
      FileUtils.mkdir_p(skill_dir)
      FileUtils.cp(skill_file, skill_dir.join("SKILL.md"))
    end
  end
end
