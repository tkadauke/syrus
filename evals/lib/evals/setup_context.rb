module Evals
  # instance_eval'd against a scenario's optional setup.rb, so scenarios that
  # need more than "commit these seed files" (e.g. the rebase scenario needs
  # a real diverged-and-conflicting branch pair) can script arbitrary git
  # setup against the freshly-built fixture workspace.
  class SetupContext
    attr_reader :workspace_path

    def initialize(workspace_path)
      @workspace_path = workspace_path
    end

    def sh(*cmd)
      Dir.chdir(workspace_path) do
        raise "command failed (#{$?&.exitstatus}): #{cmd.join(' ')}" unless system(*cmd)
      end
    end

    def write(relative_path, content)
      full_path = File.join(workspace_path, relative_path)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, content)
    end
  end
end
