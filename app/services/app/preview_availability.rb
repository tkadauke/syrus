require "shellwords"

module App
  # Shared "is a preview even possible for this repository" check, used by
  # JobDetailPayload's can_start_preview action and the simple-mode dashboard
  # row's Preview & Approve action. Detects either a registered
  # `:preview_provider` plugin or a `.syrus.yml` `preview:` block read
  # straight off the repository's local bare clone (no GitHub API call, so
  # this stays cheap enough to call per dashboard row).
  class PreviewAvailability
    def self.configured?(repository)
      Syrus::Plugin::PreviewProvider.configured? || syrus_yml_has_preview?(repository)
    end

    def self.syrus_yml_has_preview?(repository)
      clone_path = File.join(
        ENV.fetch("SYRUS_DATA_ROOT", File.expand_path("~/.syrus")),
        "clones",
        "#{repository.id}.git"
      )
      return false unless File.directory?(clone_path)

      yml_content = `git --git-dir #{clone_path.shellescape} show HEAD:.syrus.yml 2>/dev/null`
      return false unless $?.success? && yml_content.present?

      SyrusYml.new(yml_content).parse.preview.present?
    rescue StandardError
      false
    end
  end
end
