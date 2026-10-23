require "fileutils"
require "pathname"
require "securerandom"
require "socket"

class WorkerStorageIdentity
  FILE_NAME = ".syrus-worker-storage-id".freeze
  MAX_KEY_BYTES = 128
  SAFE_KEY_PATTERN = /[^a-zA-Z0-9_.-]/.freeze

  def self.key(data_root: default_data_root)
    new(data_root: data_root).key
  end

  def self.queue_key(data_root: default_data_root)
    sanitize(key(data_root: data_root))
  end

  def self.queue_name(data_root: default_data_root)
    "resume-#{queue_key(data_root: data_root)}"
  end

  # Unlike the storage-affinity queue, this queue identifies exactly one
  # worker host. Distributed immutable-source work uses it for a one-hop
  # admission reroute even when several workers mount the same data root.
  def self.dispatch_queue_name(hostname: Socket.gethostname)
    "worker-#{sanitize(hostname)}"
  end

  def self.sanitize(value)
    sanitized = value.to_s.strip.gsub(SAFE_KEY_PATTERN, "-").byteslice(0, MAX_KEY_BYTES)
    sanitized unless sanitized.empty?
  end

  def self.default_data_root
    Pathname.new(ENV["SYRUS_DATA_ROOT"] || File.expand_path("~/.syrus"))
  end

  def initialize(data_root:)
    @data_root = Pathname.new(data_root.to_s)
  end

  def key
    existing = read_existing
    return existing if existing

    create
  end

  private

  attr_reader :data_root

  def path
    data_root.join(FILE_NAME)
  end

  def read_existing
    return unless path.file?

    self.class.sanitize(path.read)
  rescue StandardError => e
    Rails.logger.warn("[WorkerStorageIdentity] failed to read #{path}: #{e.class}: #{e.message}") if defined?(Rails)
    nil
  end

  def create
    FileUtils.mkdir_p(data_root)
    value = SecureRandom.uuid
    File.write(path, "#{value}\n", mode: "wx")
    value
  rescue Errno::EEXIST
    read_existing || raise
  rescue StandardError => e
    Rails.logger.warn("[WorkerStorageIdentity] failed to create #{path}: #{e.class}: #{e.message}") if defined?(Rails)
    self.class.sanitize(Socket.gethostname)
  end
end
