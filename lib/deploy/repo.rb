# frozen_string_literal: true

module Deploy
  # The git side of a deploy: what revision is being shipped, whether the tree
  # is fit to ship, and the release tags that record what landed.
  class Repo
    attr_reader :shell, :reporter

    def initialize(shell:, reporter:)
      @shell = shell
      @reporter = reporter
    end

    # Porcelain status, not `diff-index`. `diff-index` trusts cached stat
    # information and reports a false positive after a file is touched and
    # restored byte-for-byte -- which makes an interactive `git status` look
    # like it "fixed" the deploy, because running it is what refreshed the
    # index. Porcelain status performs that refresh itself, and also catches
    # untracked files, which a deploy from a dirty tree has no business
    # ignoring.
    def assert_clean!
      dirty = git("status", "--porcelain=v1", "--untracked-files=normal").out
      return if dirty.strip.empty?

      raise Failure.new("uncommitted changes — commit or stash first", detail: dirty)
    end

    def sha
      @sha ||= git("rev-parse", "--short", "HEAD").out.strip
    end

    def branch
      @branch ||= git("rev-parse", "--abbrev-ref", "HEAD").out.strip
    end

    # The revision whose images this build can be compared against, so an
    # unchanged plugin image is re-tagged in the registry instead of rebuilt.
    # Prefer the cluster that is actually being deployed to; deploying only
    # staging and diffing against production's tag would compare against a
    # revision this build is not replacing.
    def image_base_sha(prefer_production:, prefer_staging:)
      candidates = []
      candidates << "production" if prefer_production
      candidates << "staging" if prefer_staging

      candidates.each do |ref|
        next unless tag_exists?(ref)

        return git("rev-parse", "--short", "#{ref}^{commit}").out.strip
      end
      nil
    end

    def paths_unchanged_since?(base_sha, path)
      git("diff", "--quiet", "#{base_sha}..#{sha}", "--", path).success?
    end

    def tag_exists?(ref)
      git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}").success?
    end

    # The release tag is a record, not a trigger; nothing watches it. It is
    # force-moved because it names "what is deployed", which is a position, not
    # a history.
    def move_release_tag(name)
      shell.write([ "git", "tag", "-f", name, sha ])
      shell.write([ "git", "push", "--force", "origin", name ])
    end

    def toplevel
      @toplevel ||= git("rev-parse", "--show-toplevel").out.strip
    end

    private

    def git(*args)
      shell.read([ "git", *args ], label: "git")
    end
  end
end
