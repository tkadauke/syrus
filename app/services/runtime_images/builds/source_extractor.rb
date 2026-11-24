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
      # Conservative on-disk cost model: every inode (file, directory, symlink,
      # and each directory created implicitly for a nested path) is charged one
      # filesystem block, and file data is rounded up to whole blocks. This keeps
      # many empty or tiny entries from slipping under a byte-count-only budget.
      MIN_BLOCK = 4096

      # block: pins the allocation unit (specs); otherwise it is measured from
      # the destination filesystem and never goes below MIN_BLOCK.
      def initialize(max_bytes: Config.max_source_bytes, max_entries: Config.max_source_entries, block: nil)
        @max_bytes = max_bytes
        @max_entries = max_entries
        @block = block
      end

      # Allocation unit of the filesystem holding path (or its nearest existing
      # ancestor): the larger of st_blksize and MIN_BLOCK, so filesystems with
      # bigger blocks (64 KiB, ZFS recordsize, ...) are charged conservatively.
      def allocation_unit(path)
        return @block if @block

        probe = File.expand_path(path)
        probe = File.dirname(probe) until File.exist?(probe) || probe == "/"
        [ File.stat(probe).blksize.to_i, MIN_BLOCK ].max
      end

      # On-disk cost of a stored file of the given logical size: whole blocks
      # plus one block for its inode.
      def allocated_bytes(size, path)
        unit = allocation_unit(path)
        (((size + unit - 1) / unit) * unit) + unit
      end

      # Returns the sha256 digest of the archive bytes as stored.
      def extract(archive_path, destination, max_bytes: @max_bytes)
        max_bytes = [ max_bytes, @max_bytes ].min
        FileUtils.mkdir_p(destination)
        root = File.realpath(destination)
        @unit = allocation_unit(root)
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
              bytes = charge(bytes, new_dirs(root, target) * @unit, max_bytes)
              FileUtils.mkdir_p(target)
            elsif entry.file?
              bytes = charge(bytes, new_dirs(root, File.dirname(target)) * @unit + @unit + round_up(entry.header.size), max_bytes)
              write_file(root, target, entry)
            elsif entry.header.typeflag == "2"
              bytes = charge(bytes, new_dirs(root, File.dirname(target)) * @unit + @unit, max_bytes)
              write_symlink(root, target, entry.header.linkname)
            else
              raise Rejected.new("source_invalid", "archive entry #{name} has an unsupported type")
            end
          end
        end
      end

      def charge(bytes, cost, max_bytes)
        bytes += cost
        raise Rejected.new("source_too_large", "source exceeds #{max_bytes} bytes") if bytes > max_bytes
        bytes
      end

      def round_up(size) = ((size + @unit - 1) / @unit) * @unit

      # Number of directories between root and path that do not exist yet.
      def new_dirs(root, path)
        count = 0
        while path != root && path.start_with?("#{root}/") && !File.exist?(path)
          count += 1
          path = File.dirname(path)
        end
        count
      end

      def write_file(root, target, entry)
        FileUtils.mkdir_p(File.dirname(target))
        ensure_inside!(root, File.dirname(target))
        raise Rejected.new("source_invalid", "archive entry overwrites a link") if File.symlink?(target)
        File.open(target, "wb", entry.header.mode.to_i & 0o755 | 0o600) { |file| IO.copy_stream(entry, file) }
      end

      def write_symlink(root, target, linkname)
        FileUtils.mkdir_p(File.dirname(target))
        ensure_inside!(root, File.dirname(target))
        resolved = File.expand_path(linkname, File.dirname(target))
        unless !linkname.start_with?("/") && (resolved == root || resolved.start_with?("#{root}/"))
          raise Rejected.new("path_traversal", "symlink #{linkname} leaves the source")
        end
        File.symlink(linkname, target)
      end

      def ensure_inside!(root, dir)
        real = File.realpath(dir)
        return if real == root || real.start_with?("#{root}/")
        raise Rejected.new("path_traversal", "archive entry escapes the source")
      end
    end
  end
end
