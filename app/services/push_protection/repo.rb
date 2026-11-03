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

    def changed_paths(from, to) = out("diff", "--name-only", "--no-renames", from, to).lines.map(&:strip)
    def dirty? = out("status", "--porcelain").present?
  end
end
