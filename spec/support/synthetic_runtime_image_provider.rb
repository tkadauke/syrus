require "digest"

# In-memory provider used to exercise the Runtime Image Service contract
# without any real registry.
class SyntheticRuntimeImageProvider < RuntimeImages::Provider
  attr_reader :calls, :store

  def initialize(key: "synthetic")
    @key = key
    @calls = []
    @store = {}
    @tags = {}
  end

  def key = @key

  def publish(request)
    @calls << [:publish, request]
    digest = "sha256:#{Digest::SHA256.hexdigest(request.payload.to_s)}"
    @store[[digest, request.platform]] ||= { revoked: false }
    @tags[request.source_ref] = digest
    RuntimeImages::PublishResult.new(digest: digest, locator: "synthetic/#{request.namespace.name}@#{digest}", platform: request.platform)
  end

  def resolve(request)
    @calls << [:resolve, request]
    digest = @tags.fetch(request.reference) { raise RuntimeImages::NotFound, "unknown reference #{request.reference}" }
    RuntimeImages::Resolution.new(digest: digest, locator: "synthetic/#{request.namespace.name}@#{digest}", platform: request.platform)
  end

  def inspect_image(request)
    @calls << [:inspect, request]
    entry = @store[[request.digest, request.platform]]
    RuntimeImages::Inspection.new(digest: request.digest, locator: nil, platform: request.platform, present: !entry.nil?, metadata: entry || {})
  end

  def pull(request)
    @calls << [:pull, request]
    raise RuntimeImages::NotFound, "missing" unless @store[[request.digest, request.platform]]
    RuntimeImages::PullResult.new(digest: request.digest, locator: request.locator, platform: request.platform)
  end

  def revoke(request)
    @calls << [:revoke, request]
    @store.fetch([request.digest, request.platform])[:revoked] = true
  end

  def retain(request)
    @calls << [:retain, request]
  end

  def delete(request)
    @calls << [:delete, request]
    @store.delete([request.digest, request.platform])
  end
end
