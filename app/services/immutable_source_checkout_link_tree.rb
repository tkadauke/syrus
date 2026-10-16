require "fileutils"

# Materializes a grader's checkout as a farm of hard links into the prepared
# tree instead of a byte-for-byte copy of it.
#
# The copy it replaces is the dominant cost of a graded landing attempt. A
# checkout is ~1.6 GB across ~69,000 entries, 71% of it `node_modules` and
# `vendor`, and `FileUtils.cp_r` walks all of it in-process for every grader in
# a fanout. Measured on a production worker: 3 to 25 minutes per grader
# depending on how many siblings are copying at the same time, to run commands
# that mostly take under a minute. The same tree links in 1.7 seconds.
#
# Hard links are safe here only because the prepared tree is shared: every
# grader on this host links against the same lower directory, so a file written
# *in place* through a link would be seen by the others. Tools in this pipeline
# overwhelmingly replace files rather than edit them -- git, bundler and npm
# all write a new file and rename it, which breaks the link harmlessly -- but
# the paths below are known exceptions (sqlite databases, appended logs,
# lockfiles a dependency install rewrites, caches), so they are unshared into
# private copies before the command runs.
class ImmutableSourceCheckoutLinkTree
  Result = Data.define(:linked, :reason, :unshared_paths) do
    def linked? = linked

    def strategy = linked ? "hardlink" : "copy"
  end

  # Written in place by a graded run, so each checkout needs its own copy.
  # Directories and single files are both allowed.
  #
  # `.git` leads the list for a reason that is easy to miss: the checkout is a
  # working tree, and nearly every git command writes to it -- the index on a
  # status, ORIG_HEAD and reflogs on a checkout, packed-refs on a fetch. Shared
  # through a link, one grader's git invocation would rewrite the repository
  # every other grader on the host is reading. It is also cheap to copy: 64 MB
  # in ~66 packed files against the 913 MB of dependencies that stay linked.
  UNSHARED_PATHS = %w[
    .git
    .bundle
    .syrus
    Gemfile.lock
    app/assets/builds
    coverage
    db
    log
    package-lock.json
    pnpm-lock.yaml
    storage
    tmp
    yarn.lock
  ].freeze

  def self.link(...) = new(...).link

  def initialize(source:, destination:, log: nil)
    @source = Pathname.new(source)
    @destination = Pathname.new(destination)
    @log = log
  end

  def link
    return failure("prepared checkout source is missing") unless source.directory?

    FileUtils.rm_rf(destination.to_s)
    FileUtils.mkdir_p(destination.to_s)
    unshared = []
    source.children.each { |child| materialize(child.basename.to_s, unshared) }
    log&.call("[immutable_source_checkout] linked workspace from #{source} (#{unshared.size} path(s) unshared)")
    Result.new(true, nil, unshared.sort)
  rescue SystemCallError => e
    # EXDEV when the prepared tree and the checkout land on different devices,
    # EPERM or EACCES where the filesystem refuses links, ENOSPC for inodes.
    # None of these are worth failing the Run over: the copy the caller falls
    # back to still works.
    FileUtils.rm_rf(destination.to_s)
    failure("hardlink materialization failed: #{e.class}: #{e.message}")
  end

  private

  attr_reader :source, :destination, :log

  def failure(reason)
    Result.new(false, reason, [])
  end

  # Walks the tree rather than handing it to FileUtils.cp_lr, because a hard
  # link is not the right answer for every entry:
  #
  # - a symlink has to be recreated as a symlink. `link(2)` dereferences one on
  #   macOS, which turned this repository's AGENTS.md -> CLAUDE.md into a plain
  #   copy of CLAUDE.md, and the checkout is supposed to be byte-identical to
  #   the prepared tree including its links.
  # - a path a graded run writes in place gets a private copy, so the write
  #   cannot reach the prepared tree the other graders on this host share.
  def materialize(relative, unshared)
    original = source.join(relative)
    linked = destination.join(relative)

    if UNSHARED_PATHS.include?(relative)
      FileUtils.cp_r(original.to_s, linked.to_s, preserve: true, dereference_root: false)
      unshared << relative
    elsif original.symlink?
      File.symlink(File.readlink(original.to_s), linked.to_s)
    elsif original.directory?
      FileUtils.mkdir_p(linked.to_s)
      FileUtils.chmod(original.stat.mode & 0o7777, linked.to_s)
      original.children.each { |child| materialize(File.join(relative, child.basename.to_s), unshared) }
    else
      File.link(original.to_s, linked.to_s)
    end
  end
end
