module Syrus
  module Plugin
    # Interface for a plugin that contributes built-in skills.
    #
    #   .skill_entries => [ { name: "coverage-gap-report", klass: "MyPlugin::GapReportSkill" } ]
    #
    # `klass` is a fully qualified constant name of a Skills::Base subclass. A
    # plugin may not shadow a skill the host defines itself; the entry is
    # dropped with a log line instead.
    module Skill
      def self.included(base) = base.extend(self)
    end
  end
end
