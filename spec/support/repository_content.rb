# A repository content provider backed by an in-memory snapshot, for core
# specs. Core code reads repository files through RepositoryContent, whose
# real providers are plugins; stubbing through this keeps core specs passing
# when those plugins are removed (see bin/plugin-boundary-audit).
#
#   stub_repository_content(repository, files: { ".syrus.yml" => "grade: []" })
#   stub_repository_content(repository, ref: "release", files: { ... })
#   stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("rate limited"))
#   stub_repository_changes(repository, head: "feature", paths: %w[app/a.rb])
#
# Re-stubbing a ref points it at a new revision; the old revision stays
# readable, as a real commit would.
class FakeRepositoryContentProvider
  include Syrus::Plugin::RepositoryContentProvider

  class << self
    def provider_key = "fake"
    def display_name = "Fake content"
    def role = :upstream

    def available_for?(repository)
      snapshots.key?(repository.id) || failures.key?(repository.id)
    end

    def build(repository:, user:)
      new(repository)
    end

    # { repository_id => { ref => { id:, files: { path => bytes } } } }
    def snapshots
      @snapshots ||= {}
    end

    # { revision_id => { files:, content_ids: } }, every revision ever stubbed
    def revisions
      @revisions ||= {}
    end

    # { head_revision_id => [paths] }
    def changed_paths
      @changed_paths ||= {}
    end

    # { [base_revision_id, head_revision_id] => { changes:, truncated: } }
    def diffs
      @diffs ||= {}
    end

    # Hook for forbid_repository_changes!.
    def changes_requested; end

    def failures
      @failures ||= {}
    end

    def calls
      @calls ||= []
    end

    def reset!
      @snapshots = {}
      @revisions = {}
      @changed_paths = {}
      @diffs = {}
      @failures = {}
      @calls = []
    end
  end

  def initialize(repository)
    @repository = repository
  end

  def resolve(ref, max_age:)
    record(:resolve, ref)
    id = self.class.revisions.key?(ref) ? ref : snapshots.dig(ref, :id)
    raise RepositoryContent::UnknownRevision, "unknown ref #{ref}" unless id

    RepositoryContent::Revision.new(id: id, ref: ref, observed_at: Time.current)
  end

  def tree(revision_id)
    record(:tree, revision_id)
    revision = revision_for(revision_id)
    entries = revision[:files].map do |path, bytes|
      RepositoryContent::Entry.new(path: path, size: bytes.bytesize, content_id: revision[:content_ids] ? Digest::SHA1.hexdigest(bytes) : nil)
    end
    raise RepositoryContent::Truncated.new("truncated", partial: entries) if revision[:truncated_tree]

    entries
  end

  def read(revision_id, path)
    record(:read, revision_id, path)
    bytes = revision_for(revision_id)[:files][path]
    raise RepositoryContent::NotFound, "#{path} not found" unless bytes

    RepositoryContent::Blob.new(path: path, bytes: bytes, content_id: Digest::SHA1.hexdigest(bytes))
  end

  # Paths registered with stub_repository_changes for the head revision, or
  # else a plain comparison of the two revisions' files.
  def changes(base_id, head_id, patch: false)
    record(:changes, base_id, head_id)
    self.class.changes_requested
    if (diff = self.class.diffs[[ base_id, head_id ]])
      changes = diff[:changes].map { |change| patch ? change : change.with(patch: nil) }
      raise RepositoryContent::Truncated.new("truncated", partial: changes) if diff[:truncated]

      return changes
    end
    base = revision_for(base_id)[:files]
    head = revision_for(head_id)[:files]
    if (paths = self.class.changed_paths[head_id])
      return paths.map { |path| RepositoryContent::Change.new(path: path, status: base.key?(path) ? "modified" : "added") }
    end

    (base.keys | head.keys).sort.filter_map do |path|
      if !base.key?(path) then RepositoryContent::Change.new(path: path, status: "added")
      elsif !head.key?(path) then RepositoryContent::Change.new(path: path, status: "deleted")
      elsif base[path] != head[path] then RepositoryContent::Change.new(path: path, status: "modified")
      end
    end
  end

  private

  def record(operation, *args)
    failure = self.class.failures[@repository.id]
    raise failure if failure

    self.class.calls << [ operation, *args ]
  end

  def snapshots
    self.class.snapshots.fetch(@repository.id, {})
  end

  def revision_for(revision_id)
    self.class.revisions[revision_id] || raise(RepositoryContent::UnknownRevision, "unknown revision #{revision_id}")
  end
end

module RepositoryContentHelpers
  # `content_ids: false` models a VCS without content addresses: tree entries
  # then carry no content_id.
  # `truncated_tree: true` makes the tree come back as a Truncated partial
  # answer, the way GitHub reports a very large tree.
  def stub_repository_content(repository, files:, ref: repository.default_branch, content_ids: true, truncated_tree: false)
    use_fake_repository_content!
    files = files.transform_values(&:to_s)
    id = Digest::SHA1.hexdigest([ repository.id, ref, files.to_a, content_ids, truncated_tree ].inspect)
    FakeRepositoryContentProvider.revisions[id] = { files: files, content_ids: content_ids, truncated_tree: truncated_tree }
    FakeRepositoryContentProvider.snapshots[repository.id] ||= {}
    FakeRepositoryContentProvider.snapshots[repository.id][ref] = { id: id, files: files }
    RepositoryContent::Revision.new(id: id, ref: ref)
  end

  # Points `head` at a revision whose change set against any base is exactly
  # `paths`. The base ref keeps whatever it was stubbed with.
  def stub_repository_changes(repository, head:, paths:, files: paths.index_with("changed"))
    revision = stub_repository_content(repository, ref: head, files: files)
    FakeRepositoryContentProvider.changed_paths[revision.id] = paths
    revision
  end

  # The changes between two refs, given the way GitHub's compare API reports
  # files ({ path:, status:, additions:, deletions:, patch: }, with
  # "removed"/"copied"/"changed" statuses). `truncated: true` makes the fake
  # raise RepositoryContent::Truncated with them as the partial answer.
  def stub_repository_diff(repository, base:, head:, files:, truncated: false)
    use_fake_repository_content!
    base_id = ensure_fake_ref(repository, base)
    head_id = ensure_fake_ref(repository, head)
    changes = files.map do |file|
      status = { "removed" => "deleted", "copied" => "added", "changed" => "modified" }.fetch(file[:status].to_s, file[:status].to_s)
      RepositoryContent::Change.new(path: file[:path], status: status, previous_path: file[:previous_path],
                                    additions: file[:additions], deletions: file[:deletions], patch: file[:patch])
    end
    FakeRepositoryContentProvider.diffs[[ base_id, head_id ]] = { changes: changes, truncated: truncated }
  end

  # Fails the example the moment anything asks for changes -- as an RSpec
  # expectation, so code that rescues StandardError cannot hide it.
  def forbid_repository_changes!
    use_fake_repository_content!
    expect(FakeRepositoryContentProvider).not_to receive(:changes_requested)
  end

  def ensure_fake_ref(repository, ref)
    existing = FakeRepositoryContentProvider.snapshots.dig(repository.id, ref, :id)
    existing || stub_repository_content(repository, ref: ref, files: {}).id
  end

  def stub_repository_content_failure(repository, error)
    use_fake_repository_content!
    FakeRepositoryContentProvider.failures[repository.id] = error
  end

  def use_fake_repository_content!
    RepositoryContent.provider_classes_override = [ FakeRepositoryContentProvider ]
  end
end

RSpec.configure do |config|
  config.include RepositoryContentHelpers
  # Every spec reads repository content through the fake unless it opts out
  # (`RepositoryContent.provider_classes_override = nil`, as a provider
  # plugin's own specs do). Core code must never depend on a particular
  # provider plugin -- they are removable -- and a repository nothing has
  # stubbed then reads as "no provider serves it", which every caller already
  # treats as unavailable. Without this, any spec that doubles GithubClient
  # and happens to build a Workflow (which reads .syrus.yml) would hand the
  # double calls it does not expect.
  config.before do
    RepositoryContent.provider_classes_override = [ FakeRepositoryContentProvider ]
  end
  config.after do
    RepositoryContent.provider_classes_override = nil
    FakeRepositoryContentProvider.reset!
  end
end
