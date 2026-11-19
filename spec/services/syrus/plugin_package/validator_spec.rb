require "rails_helper"
require "rubygems/package"
require "zlib"

RSpec.describe Syrus::PluginPackage::Validator do
  def archive(entries, manifest: nil, checksums: nil)
    plugin_files = entries.transform_values { |value| value.fetch(:data) }
    manifest ||= {
      "format_version" => 1, "name" => "weather", "version" => "1.2.3", "requires_syrus" => ">= 1.0",
      "roles" => [], "extension_points" => [], "routes" => [], "credential_types" => [], "cli_commands" => [],
      "frontend" => {}, "locales" => [], "public_host_apis" => [],
      "files" => plugin_files.map { |path, data| { "path" => path, "sha256" => Digest::SHA256.hexdigest(data) } }.sort_by { |item| item["path"] }
    }
    package = { "package.json" => JSON.pretty_generate(manifest) + "\n", **plugin_files }
    package["CHECKSUMS.sha256"] = checksums || package.sort.map { |path, data| "#{Digest::SHA256.hexdigest(data)}  #{path}\n" }.join
    io = StringIO.new
    Zlib::GzipWriter.wrap(io) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        package.sort.each { |path, data| tar.add_file_simple(path, entries.dig(path, :mode) || 0o644, data.bytesize) { |file| file.write(data) } }
      end
    end
    StringIO.new(io.string)
  end

  let(:gemspec) do
    <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "weather"
        spec.version = "1.2.3"
        spec.metadata["requires_syrus"] = ">= 1.0"
        spec.add_dependency "rails", ">= 8.1"
      end
    RUBY
  end
  let(:entries) { { "plugin/weather.gemspec" => { data: gemspec }, "plugin/lib/weather.rb" => { data: "module Weather; end\n" } } }

  it "accepts a valid package" do
    expect(described_class.new(archive(entries)).call).to be_valid
  end

  it "rejects a tampered file" do
    files = entries.map { |path, item| { "path" => path, "sha256" => Digest::SHA256.hexdigest(item[:data]) } }
    files.find { |item| item["path"].end_with?("weather.rb") }["sha256"] = "0" * 64
    manifest = { "format_version" => 1, "name" => "weather", "version" => "1.2.3", "requires_syrus" => ">= 1.0", "files" => files }
    expect(described_class.new(archive(entries, manifest:)).call.errors.join).to include("manifest file list does not match")
  end

  it "rejects a checksum file that does not match the package contents" do
    checksums = "#{"0" * 64}  plugin/lib/weather.rb\n"

    expect(described_class.new(archive(entries, checksums:)).call.errors.join).to include("checksum file does not match")
  end

  it "rejects an unsupported package format version" do
    manifest = {
      "format_version" => 2, "name" => "weather", "version" => "1.2.3", "requires_syrus" => ">= 1.0",
      "files" => entries.map { |path, item| { "path" => path, "sha256" => Digest::SHA256.hexdigest(item[:data]) } }
    }

    expect(described_class.new(archive(entries, manifest:)).call.errors).to include("unsupported package format version")
  end

  it "rejects traversal paths" do
    bad = entries.merge("../escape" => { data: "bad" })
    expect(described_class.new(archive(bad)).call.errors.join).to include("unsafe package path")
  end

  it "rejects symlink escapes" do
    io = StringIO.new
    Zlib::GzipWriter.wrap(io) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        header = Gem::Package::TarHeader.new(
          name: "plugin/escape", mode: 0o777, size: 0, typeflag: "2", linkname: "../../outside",
          uid: 0, gid: 0, mtime: 0, checksum: "", uname: "", gname: "", devmajor: 0, devminor: 0, prefix: ""
        )
        tar.instance_variable_get(:@io).write(header.to_s)
      end
    end
    expect(described_class.new(StringIO.new(io.string)).call.errors.join).to include("package contains links")
  end

  it "rejects oversized files" do
    expect(described_class.new(archive(entries), max_file_size: 10).call.errors.join).to include("too large")
  end

  it "rejects a mismatched manifest" do
    bad = { "format_version" => 1, "name" => "other", "version" => "1.2.3", "requires_syrus" => ">= 1.0", "files" => entries.map { |path, item| { "path" => path, "sha256" => Digest::SHA256.hexdigest(item[:data]) } } }
    expect(described_class.new(archive(entries, manifest: bad)).call.errors.join).to include("manifest name does not match")
  end

  it "rejects gem dependencies" do
    bad = entries.deep_dup
    bad["plugin/weather.gemspec"][:data] += "spec.add_dependency \"octokit\"\n"
    expect(described_class.new(archive(bad)).call.errors.join).to include("unsupported gem dependencies")
  end

  it "rejects non-public host APIs" do
    bad = entries.merge("plugin/lib/bad.rb" => { data: "Job.find(1)\n" })
    expect(described_class.new(archive(bad)).call.errors.join).to include("non-public Syrus API")
  end

  it "accepts plugin constants whose names start with core constant names" do
    prefixed = entries.merge("plugin/lib/runner.rb" => { data: "module Weather; class Runner; end; end\n" })

    expect(described_class.new(archive(prefixed)).call).to be_valid
  end
end
