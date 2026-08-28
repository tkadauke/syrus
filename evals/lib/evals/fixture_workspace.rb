module Evals
  # Builds a disposable git repo the agent operates in, mirroring the shape
  # of a real WorkflowWorkspace clone closely enough for the agent's git
  # tooling (git diff/log/rebase) to behave the same way it would against a
  # real Syrus-managed checkout.
  module FixtureWorkspace
    def self.build(scenario)
      path = Dir.mktmpdir("syrus-eval-#{scenario.slug}-")
      FileUtils.cp_r("#{scenario.fixture_dir}/.", path) if scenario.fixture_dir
      init_git!(path)
      SetupContext.new(path).instance_eval(File.read(scenario.setup_script), scenario.setup_script) if scenario.setup_script
      path
    end

    def self.init_git!(path)
      Dir.chdir(path) do
        run!("git", "init", "--quiet", "--initial-branch=main")
        run!("git", "config", "user.email", "eval@syrus.local")
        run!("git", "config", "user.name", "Syrus Eval")
        if Dir.glob("*", base: path).any? || Dir.glob(".[^.]*", base: path).any?
          run!("git", "add", "-A")
          run!("git", "commit", "--quiet", "-m", "Seed fixture repo")
        else
          run!("git", "commit", "--quiet", "--allow-empty", "-m", "Seed fixture repo (empty)")
        end
      end
    end

    def self.run!(*cmd)
      raise "command failed (#{$?&.exitstatus}): #{cmd.join(' ')}" unless system(*cmd)
    end
    private_class_method :run!

    def self.head_sha(path)
      Dir.chdir(path) { `git rev-parse HEAD 2>/dev/null`.strip }
    end

    # The invariant the real git pipeline contract depends on
    # (commit_agent_changes -> git diff origin/<default_branch>...HEAD ->
    # push -> open PR): the agent's final HEAD must still share history
    # with the commit it started from. False means the agent did something
    # equivalent to an orphan checkout / hard reset to an unrelated commit /
    # `rm -rf .git && git init` — disqualifying regardless of the rubric.
    def self.history_intact?(path, base_sha)
      return false unless File.directory?(File.join(path, ".git"))

      Dir.chdir(path) do
        current = `git rev-parse HEAD 2>/dev/null`.strip
        return false if current.empty?

        system("git", "merge-base", "--is-ancestor", base_sha, "HEAD", out: File::NULL, err: File::NULL)
      end
    end

    def self.diff(path, base_sha)
      Dir.chdir(path) { `git diff #{base_sha}...HEAD 2>/dev/null` }
    end

    def self.cleanup(path)
      FileUtils.remove_entry(path) if path && File.exist?(path)
    end
  end
end
