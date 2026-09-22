# A repository content provider backed by an in-memory snapshot, for core
# specs. Core code reads repository files through RepositoryContent, whose
# real providers are plugins; stubbing through this keeps core specs passing
# when those plugins are removed (see bin/plugin-boundary-audit).
#
#   stub_repository_content(repository, files: { ".syrus.yml" => "grade: []" })
#   stub_repository_content(repository, ref: "release", files: { ... })
#   stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("rate limited"))
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

    def failures
      @failures ||= {}
    end

    def calls
      @calls ||= []
    end

    def reset!
      @snapshots = {}
      @failures = {}
      @calls = []
    end
  end

  def initialize(repository)
    @repository = repository
  end

  def resolve(ref, max_age:)
    record(:resolve, ref)
    snapshot = snapshots.values.find { |candidate| candidate[:id] == ref } || snapshots[ref]
    raise RepositoryContent::UnknownRevision, "unknown ref #{ref}" unless snapshot

    RepositoryContent::Revision.new(id: snapshot[:id], ref: ref, observed_at: Time.current)
  end

  def tree(revision_id)
    record(:tree, revision_id)
    snapshot_for(revision_id)[:files].map do |path, bytes|
      RepositoryContent::Entry.new(path: path, size: bytes.bytesize, content_id: Digest::SHA1.hexdigest(bytes))
    end
  end

  def read(revision_id, path)
    record(:read, revision_id, path)
    bytes = snapshot_for(revision_id)[:files][path]
    raise RepositoryContent::NotFound, "#{path} not found" unless bytes

    RepositoryContent::Blob.new(path: path, bytes: bytes, content_id: Digest::SHA1.hexdigest(bytes))
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

  def snapshot_for(revision_id)
    snapshots.values.find { |snapshot| snapshot[:id] == revision_id } ||
      raise(RepositoryContent::UnknownRevision, "unknown revision #{revision_id}")
  end
end

module RepositoryContentHelpers
  def stub_repository_content(repository, files:, ref: repository.default_branch)
    use_fake_repository_content!
    id = Digest::SHA1.hexdigest([ repository.id, ref, files.to_a ].inspect)
    FakeRepositoryContentProvider.snapshots[repository.id] ||= {}
    FakeRepositoryContentProvider.snapshots[repository.id][ref] = { id: id, files: files.transform_values(&:to_s) }
    RepositoryContent::Revision.new(id: id, ref: ref)
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
  config.after do
    RepositoryContent.provider_classes_override = nil
    FakeRepositoryContentProvider.reset!
  end
end
