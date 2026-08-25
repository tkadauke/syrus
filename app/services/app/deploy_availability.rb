require "shellwords"

module App
  # Shared "is a manual deploy even possible for this repository" check,
  # used by JobDetailPayload's can_deploy action flag and
  # JobDeployController's approval gate. Reads `.syrus.yml`'s `deploy:`
  # block straight off the repository's local bare clone (no GitHub API
  # call), mirroring PreviewAvailability's read-the-bare-clone approach.
  class DeployAvailability
    def self.configured?(repository)
      deploy_config(repository).present?
    end

    def self.allow_unapproved?(repository)
      deploy_config(repository)&.allow_unapproved || false
    end

    def self.deploy_config(repository)
      clone_path = File.join(
        ENV.fetch("SYRUS_DATA_ROOT", File.expand_path("~/.syrus")),
        "clones",
        "#{repository.id}.git"
      )
      return nil unless File.directory?(clone_path)

      yml_content = `git --git-dir #{clone_path.shellescape} show HEAD:.syrus.yml 2>/dev/null`
      return nil unless $?.success? && yml_content.present?

      SyrusYml.new(yml_content).parse.deploy
    rescue StandardError
      nil
    end
  end
end
