require "rubygems/package"
require "zlib"
require "digest"
require "fileutils"

module RuntimeImages
  module Builds
    # Unpacks a source archive (tar or tar.gz) into an empty directory with
    # ceilings on entries and bytes, rejecting anything that could write
    # outside it: absolute or ".." paths, hardlinks, device nodes, and
    # symlinks that leave the tree.
    class SourceExtractor
      def initialize(max_bytes: Config.max_source_bytes, max_entries: Config.max_source_entries)
        @max_bytes = max_bytes
        @max_entries = max_entries
      end

      # Returns the sha256 digest of the archive bytes as stored. Meant to run
      # inside the build's size-bounded tmpfs namespace (see
      # bin/extract-runtime-image-source): the kernel enforces the aggregate
      # on-disk ceiling there, so only logical ceilings are counted here and an
      # ENOSPC from the bounded filesystem is reported as an oversized source.
      def extract(archive_path, destination, max_bytes: @max_bytes)
        max_bytes = [ max_bytes, @max_bytes ].min
        FileUtils.mkdir_p(destination)
        root = File.realpath(destination)
        digest = Digest::SHA256.file(archive_path).hexdigest
        File.open(archive_path, "rb") do |raw|
          gzip = raw.read(2) == "\x1F\x8B".b
          raw.rewind
          io = gzip ? Zlib::GzipReader.new(raw) : raw
          unpack(io, root, max_bytes)
        end
        "sha256:#{digest}"
      rescue Gem::Package::TarInvalidError, Zlib::Error => e
        raise Rejected.new("source_unreadable", "source archive could not be read: #{e.message}")
      rescue Errno::ENOSPC, Errno::EDQUOT
        raise Rejected.new("source_too_large", "source does not fit the build storage ceiling")
      end

      private

      def unpack(io, root, max_bytes)
        entries = 0
        bytes = 0
        Gem::Package::TarReader.new(io) do |tar|
          tar.each do |entry|
            entries += 1
            raise Rejected.new("source_too_large", "source has more than #{@max_entries} entries") if entries > @max_entries
            name = BuildPaths.relative!(entry.full_name.delete_prefix("./"), what: "archive entry")
            target = File.join(root, name)
            if entry.directory?
              make_dir_inside!(root, target)
            elsif entry.file?
              bytes = charge(bytes, entry.header.size, max_bytes)
              write_file(root, target, entry)
            elsif entry.header.typeflag == "2"
              write_symlink(root, target, entry.header.linkname)
            else
              raise Rejected.new("source_invalid", "archive entry #{name} has an unsupported type")
            end
          end
        end
        verify_links_inside!(root)
      end

      def charge(bytes, cost, max_bytes)
        bytes += cost
        raise Rejected.new("source_too_large", "source exceeds #{max_bytes} bytes") if bytes > max_bytes
        bytes
      end

      def write_file(root, target, entry)
        make_dir_inside!(root, File.dirname(target))
        raise Rejected.new("source_invalid", "archive entry overwrites a link") if File.symlink?(target)
        File.open(target, "wb", entry.header.mode.to_i & 0o755 | 0o600) { |file| IO.copy_stream(entry, file) }
      end

      # The lexical check only rejects early; it does not follow links, so
      # "d" -> "." then "d/x" -> ".." passes it while d/x really is the root's
      # parent (F137). What a link really resolves to is checked once the tree
      # is complete (verify_links_inside!), and every directory is checked
      # through its real path before anything is created in it.
      def write_symlink(root, target, linkname)
        make_dir_inside!(root, File.dirname(target))
        resolved = File.expand_path(linkname, File.realpath(File.dirname(target)))
        unless !linkname.start_with?("/") && (resolved == root || resolved.start_with?("#{root}/"))
          raise Rejected.new("path_traversal", "symlink #{linkname} leaves the source")
        end
        File.symlink(linkname, target)
      end

      # Checks the deepest existing ancestor through its real path before
      # creating anything, so a directory is never made outside the source,
      # then the created directory itself.
      def make_dir_inside!(root, dir)
        ensure_inside!(root, deepest_existing(dir))
        FileUtils.mkdir_p(dir)
        ensure_inside!(root, dir)
      rescue Errno::EEXIST, Errno::ENOTDIR, Errno::ELOOP
        raise Rejected.new("source_invalid", "archive entry #{dir.delete_prefix("#{root}/")} cannot be created")
      end

      def deepest_existing(path)
        path = File.dirname(path) until File.exist?(path) || path == File.dirname(path)
        path
      end

      # Every link that resolves at all must resolve inside the source; a
      # dangling link points at nothing and is left alone.
      def verify_links_inside!(root)
        Dir.glob("**/*", File::FNM_DOTMATCH, base: root).each do |relative|
          path = File.join(root, relative)
          next unless File.symlink?(path)

          real = begin
            File.realpath(path)
          rescue Errno::ENOENT, Errno::ELOOP
            next
          end
          next if real == root || real.start_with?("#{root}/")

          raise Rejected.new("path_traversal", "symlink #{relative} leaves the source")
        end
      end

      def ensure_inside!(root, dir)
        real = File.realpath(dir)
        return if real == root || real.start_with?("#{root}/")
        raise Rejected.new("path_traversal", "archive entry escapes the source")
      end
    end
  end
end
