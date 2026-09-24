require "shellwords"

module Ruby
  # :autofix_command for RuboCop's built-in autocorrect. Only offers the
  # command when a .rubocop.yml is present — running `rubocop -a` on a repo
  # with no rubocop config at all would apply RuboCop's default cop set
  # instead of the repo's own conventions.
  class RubocopAutofix
    def self.autofix_command(workspace_path:, changed_files:)
      return nil unless Pathname.new(workspace_path).join(".rubocop.yml").exist?

      files = Array(changed_files).select { |file| file.end_with?(".rb", ".rake", ".gemspec") }
      return nil if files.empty?

      "bundle exec rubocop -a -- #{Shellwords.join(files)}"
    end
  end
end
