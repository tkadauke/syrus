require "rails_helper"
require "tmpdir"

RSpec.describe GitMergeDrivers do
  let(:root) { Pathname.new(Dir.mktmpdir("git-merge-drivers")) }
  let(:git) { instance_double(GitRunner, run: "") }

  after { FileUtils.rm_rf(root) }

  def attributes(value) = root.join(".gitattributes").write(value)

  def script(name, executable: true)
    path = root.join("bin", name)
    path.dirname.mkpath
    path.write("#!/bin/sh\n")
    FileUtils.chmod(executable ? 0o755 : 0o644, path)
    path
  end

  it "resolves an underscore attribute to a hyphenated executable" do
    attributes("db/schema.rb merge=ruby_schema\n")
    path = script("merge-ruby-schema")

    result = described_class.register!(git: git, path: root)

    expect(result).to be_registered("ruby_schema")
    expect(git).to have_received(:run).with("config", "merge.ruby_schema.driver", "#{path.expand_path} %O %A %B", chdir: root.to_s)
  end

  it "prefers an exact-name executable" do
    attributes("file merge=custom_name\n")
    exact = script("merge-custom_name")
    script("merge-custom-name")

    described_class.register!(git: git, path: root)

    expect(git).to have_received(:run).with("config", "merge.custom_name.driver", "#{exact.expand_path} %O %A %B", chdir: root.to_s)
  end

  it "warns with the attribute and candidate paths when the executable is missing" do
    attributes("file merge=missing_driver\n")

    expect(Rails.logger).to receive(:warn).with(include("merge=missing_driver", "merge-missing_driver", "merge-missing-driver"))
    expect(described_class.register!(git: git, path: root).drivers).to be_empty
    expect(git).not_to have_received(:run)
  end

  it "does not register a non-executable script" do
    attributes("file merge=locked\n")
    script("merge-locked", executable: false)
    allow(Rails.logger).to receive(:warn)

    expect(described_class.register!(git: git, path: root).drivers).to be_empty
  end

  it "does nothing without .gitattributes" do
    expect(described_class.register!(git: git, path: root).drivers).to be_empty
    expect(git).not_to have_received(:run)
  end

  it "registers multiple distinct attributes" do
    attributes("a merge=one\nb merge=two\nc merge=one\n")
    script("merge-one")
    script("merge-two")

    expect(described_class.register!(git: git, path: root).drivers.keys).to contain_exactly("one", "two")
  end

  it "is idempotent" do
    attributes("file merge=stable\n")
    script("merge-stable")

    2.times { described_class.register!(git: git, path: root) }

    expect(git).to have_received(:run).with("config", "merge.stable.name", anything, chdir: root.to_s).twice
    expect(git).to have_received(:run).with("config", "merge.stable.driver", anything, chdir: root.to_s).twice
  end
end
