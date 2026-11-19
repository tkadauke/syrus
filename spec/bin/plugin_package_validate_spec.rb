require "rails_helper"
require "open3"
require "rubygems/package"
require "zlib"

RSpec.describe "bin/plugin-package-validate" do
  let(:script) { Rails.root.join("bin/plugin-package-validate").to_s }

  def write_package(path)
    gemspec = <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "weather"
        spec.version = "1.2.3"
        spec.metadata["requires_syrus"] = ">= 1.0"
      end
    RUBY
    plugin_files = {
      "plugin/weather.gemspec" => gemspec,
      "plugin/lib/weather.rb" => "module Weather; end\n"
    }
    manifest = {
      "format_version" => 1, "name" => "weather", "version" => "1.2.3", "requires_syrus" => ">= 1.0",
      "roles" => [], "extension_points" => [], "routes" => [], "credential_types" => [], "cli_commands" => [],
      "frontend" => {}, "locales" => [], "public_host_apis" => [],
      "files" => plugin_files.map do |entry, data|
        { "path" => entry, "sha256" => Digest::SHA256.hexdigest(data) }
      end.sort_by { |item| item.fetch("path") }
    }
    entries = { "package.json" => JSON.pretty_generate(manifest) + "\n", **plugin_files }
    entries["CHECKSUMS.sha256"] = entries.sort.map do |entry, data|
      "#{Digest::SHA256.hexdigest(data)}  #{entry}\n"
    end.join

    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        entries.sort.each do |entry, data|
          tar.add_file_simple(entry, 0o644, data.bytesize) { |file| file.write(data) }
        end
      end
    end
  end

  it "provides a machine-readable registry validation boundary" do
    Dir.mktmpdir("plugin-package-command") do |directory|
      package = File.join(directory, "weather.tar.gz")
      write_package(package)

      stdout, stderr, status = Open3.capture3(script, "--json", package, chdir: Rails.root.to_s)

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(JSON.parse(stdout)).to include("valid" => true, "errors" => [])
    end
  end

  it "returns a nonzero status and errors for an invalid package" do
    Dir.mktmpdir("plugin-package-command") do |directory|
      package = File.join(directory, "invalid.tar.gz")
      File.binwrite(package, "not an archive")

      stdout, _stderr, status = Open3.capture3(script, "--json", package, chdir: Rails.root.to_s)

      expect(status).not_to be_success
      expect(JSON.parse(stdout)).to include("valid" => false)
      expect(JSON.parse(stdout).fetch("errors")).not_to be_empty
    end
  end
end
