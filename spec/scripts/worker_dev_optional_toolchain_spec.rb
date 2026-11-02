require "spec_helper"

# Regression: a production deploy carrying 33 commits died in the worker-dev
# image build with `402 Payment Required` from dl.cloudsmith.io -- a quota on
# the mull project's package host, an account Syrus has no relationship with.
# Mull is one optional grader capability; the Debian toolchain in the same
# layer is not optional, and a third-party apt source breaks `apt-get update`
# for every source, so that outage took clang, cmake, Qt6 and the MySQL client
# down with it.
RSpec.describe "worker-dev optional toolchain" do
  let(:dockerfile) { File.read(File.expand_path("../../Dockerfile", __dir__)) }

  # The layer that installs the Debian packages.
  let(:required_layer) { dockerfile[/apt-get install --no-install-recommends -y \\\n\s+build-essential.*?rm -rf \/var\/lib\/apt\/lists/m] }
  # The layer that tries for mull.
  let(:optional_layer) { dockerfile[/install_mull\(\) \{.*?rm -rf \/var\/lib\/apt\/lists\/\* \/var\/cache\/apt\/archives\/\*/m] }

  it "installs the Debian toolchain without any third-party source configured" do
    expect(required_layer).not_to be_nil
    expect(required_layer).not_to include("cloudsmith")
    expect(required_layer).not_to include("mull-${MULL_LLVM_VERSION}")
    expect(required_layer).not_to include("sources.list.d")
  end

  it "keeps the non-optional toolchain in that layer" do
    %w[build-essential clang cmake qt6-base-dev default-mysql-client python3].each do |package|
      expect(required_layer).to include(package)
    end
  end

  it "treats mull as allowed to fail" do
    expect(optional_layer).not_to be_nil
    # Each fallible step returns rather than aborting, and the caller branches.
    expect(optional_layer).to include("|| return 1")
    expect(optional_layer).to include("if install_mull; then")
    expect(optional_layer).to include("WARNING: mull")
  end

  # A silently missing toolchain is its own kind of incident, so the absence
  # has to be observable rather than inferred from a grader's odd output.
  it "records whether mull is present" do
    expect(optional_layer).to include("/opt/syrus/mull-status")
    expect(optional_layer.scan("/opt/syrus/mull-status").length).to eq(2)
  end

  # Leaving a broken source configured would poison any later apt-get update in
  # this image, which is the failure mode that made this layer load-bearing.
  it "removes the third-party source when it could not be used" do
    expect(optional_layer).to include("rm -f /etc/apt/sources.list.d/mull-project-mull-stable.list")
  end

  # The install layer degrading gracefully is worthless if a later layer
  # asserts the tool is there. A smoke check did exactly that and failed the
  # next build with exit 127, after the install had correctly warned and
  # carried on. So the rule is about the whole file, not one layer.
  # The install layer degrading gracefully is worthless if a later layer
  # asserts the tool is there. A smoke check did exactly that and failed the
  # next build with exit 127, after the install had correctly warned and
  # carried on. So the rule covers every RUN in the file, not one layer: any
  # instruction that touches mull must either be the tolerant installer or be
  # guarded by mull-runner actually existing.
  it "has no RUN instruction that hard-requires mull" do
    runs = dockerfile.scan(/^RUN(?:.*?\\\n)*.*$/)
    touching_mull = runs.select { |run| run.include?("mull-runner") || run.include?("mull-${MULL_LLVM_VERSION}") || run.include?("mull-18") }
    expect(touching_mull).not_to be_empty, "expected to find the mull instructions this guards"

    offenders = touching_mull.reject do |run|
      run.include?("|| return 1") || run.include?("-x /usr/local/bin/mull-runner")
    end

    expect(offenders).to be_empty, -> { "unguarded mull requirement:\n#{offenders.map { |run| run.lines.first.strip[0, 90] }.join("\n")}" }
  end

  it "still checks clang strictly, since that half is not optional" do
    expect(dockerfile).to match(/RUN clang\+\+-18 --version && clang\+\+ --version \| grep -q "version 18"\s*$/)
  end

  it "still verifies the signing key fingerprint before trusting the repository" do
    expect(optional_layer).to include("MULL_APT_GPG_FINGERPRINT")
    expect(optional_layer).to include("gpg --show-keys")
  end
end
