module SyrusCoverage
  class SkillProvider
    def self.skill_entries
      [ { name: "coverage-gap-report", klass: "SyrusCoverage::GapReportSkill" } ]
    end
  end
end
