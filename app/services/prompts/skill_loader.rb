module Prompts
  # Reads a skill file, strips its YAML frontmatter, and substitutes
  # the $ARGUMENTS placeholder with the supplied context text. Used by
  # prompt classes that delegate their static instruction text to a
  # skill file while composing the dynamic, run-specific input in Ruby.
  module SkillLoader
    def self.render(skill_path, arguments)
      raw = File.read(skill_path)
      body = raw.sub(/\A---\n.*?\n---\n+/m, "").strip
      body.gsub("$ARGUMENTS", arguments)
    end
  end
end
