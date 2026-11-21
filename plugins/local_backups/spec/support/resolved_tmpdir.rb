# frozen_string_literal: true

require "tmpdir"

# LocalBackups::StorageRoot rejects a backup root with a symlink component, and
# the restore reports resolved paths. On macOS the temp directory lives under
# /var, a symlink to /private/var, so every root these specs build under
# Dir.mktmpdir was rejected there. Resolve it for this plugin's examples only:
# a suite-wide change lengthens every temp path, which overflows the 104-byte
# Unix socket path limit other specs rely on. On Linux this is a no-op.
RSpec.configure do |config|
  config.around(:each, file_path: %r{plugins/local_backups/spec/}) do |example|
    original = ENV["TMPDIR"]
    ENV["TMPDIR"] = File.realpath(Dir.tmpdir)
    example.run
  ensure
    original.nil? ? ENV.delete("TMPDIR") : ENV["TMPDIR"] = original
  end
end
