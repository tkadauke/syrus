module PushProtection
  # Small read helper over GitRunner shared by the candidate preparer, the
  # topology validator and the reconstructor.
  class Repo
    attr_reader :path

    def initialize(path, git: GitRunner.new)
      @path = path.to_s
      @git = git
    end

    def run(*args, env: {}) = @git.run(*args, chdir: path, env: env)

    def out(*args, env: {}) = run(*args, env: env).strip

    def head = out("rev-parse", "HEAD")
    def tree(rev) = out("rev-parse", "#{rev}^{tree}")
    def parents(rev) = out("rev-list", "--parents", "-n", "1", rev).split.drop(1)
    def commit_exists?(sha) = (run("cat-file", "-e", "#{sha}^{commit}") && true rescue false)

    def ancestor?(ancestor, descendant)
      run("merge-base", "--is-ancestor", ancestor, descendant)
      true
    rescue GitRunner::GitError
      false
    end

    def range(anchor, tip) = out("rev-list", "--reverse", "#{anchor}..#{tip}").split

    # Every ref except the working branch, as "sha refname" lines.
    def refs_except(branch)
      out("for-each-ref", "--format=%(objectname) %(refname)").lines.map(&:strip)
        .reject { |l| l.end_with?(" refs/heads/#{branch}") }.sort
    end

    def remotes = out("remote", "-v").lines.map(&:strip).sort
    def config_text = File.read(File.join(path, ".git", "config"))

    def gitlinks(rev)
      out("ls-tree", "-r", rev).lines.select { |l| l.start_with?("160000") }.map(&:strip).sort
    end

    def gitmodules(rev)
      run("show", "#{rev}:.gitmodules")
    rescue GitRunner::GitError
      nil
    end

    # Agent-writable .git metadata that changes how git behaves (hooks run with
    # the harness's credentials, info/attributes can wire filters).
    GIT_METADATA_PATHS = %w[hooks info config.worktree].freeze

    def metadata_digest
      GIT_METADATA_PATHS.each_with_object({}) do |rel, digest|
        root = File.join(path, ".git", rel)
        entries = File.directory?(root) ? Dir.glob(File.join(root, "**", "{*,.*}"), File::FNM_DOTMATCH).sort : [ root ]
        entries.each do |entry|
          next unless File.exist?(entry) || File.symlink?(entry)
          next if File.directory?(entry) && !File.symlink?(entry)

          stat = File.lstat(entry)
          content = File.symlink?(entry) ? File.readlink(entry) : Digest::SHA256.file(entry).hexdigest
          digest[entry.delete_prefix("#{path}/.git/")] = [ format("%o", stat.mode), content ]
        end
      end
    end

    def backup_metadata(dest)
      GIT_METADATA_PATHS.each do |rel|
        src = File.join(path, ".git", rel)
        FileUtils.cp_r(src, File.join(dest, rel), preserve: true) if File.exist?(src) || File.symlink?(src)
      end
    end

    def restore_metadata(src)
      GIT_METADATA_PATHS.each do |rel|
        live = File.join(path, ".git", rel)
        FileUtils.rm_rf(live)
        backup = File.join(src, rel)
        FileUtils.cp_r(backup, live, preserve: true) if File.exist?(backup) || File.symlink?(backup)
      end
    end

    def changed_paths(from, to) = out("diff", "--name-only", "--no-renames", from, to).lines.map(&:strip)
    def dirty? = out("status", "--porcelain").present?
  end
end
