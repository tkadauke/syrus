require "rails_helper"

RSpec.describe RuntimeImages::Verifications::ImagePolicyScanner do
  let(:image) { instance_double(RuntimeImage) }
  let(:built_images) { instance_double(RuntimeImages::BuiltImages) }
  let(:source_archive) { instance_double(ActiveStorage::Attached::One, attached?: false) }
  let(:attachment) { instance_double(ActiveStorage::Attachment) }
  let(:request) { instance_double(RuntimeImageBuildRequest, source_archive: source_archive) }
  let(:log) { instance_double(RuntimeImages::Builds::LogCapture, finish: "bounded build log") }
  let(:evidence) { instance_double(RuntimeImages::Builds::Evidence, log: log) }

  it "scans image layers plus bounded history, metadata, log, and source inputs" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image@sha256:digest")
    scanned_files = nil
    runner = lambda do |argv|
      payload = if argv.first(3) == [ "docker", "image", "inspect" ]
        [ { "Size" => 10, "Config" => {} } ]
      elsif argv.first(3) == [ "docker", "image", "history" ]
        next [ "history line", 0 ]
      elsif argv.include?(described_class::SCAN_SCRIPT.to_s)
        root = argv.fetch(argv.index(described_class::SCAN_SCRIPT.to_s) + 1)
        scanned_files = Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }
          .to_h { |path| [ File.basename(path), File.binread(path) ] }
        { "Results" => [ { "Target" => "inputs", "Secrets" => [] } ] }
      else
        { "Results" => [ { "Target" => "layers", "Secrets" => [] } ] }
      end
      [ JSON.generate(payload), 0 ]
    end

    report = described_class.new(built_images: built_images, runner: runner).call(image: image, request: request, evidence: evidence)

    expect(report.secrets.fetch("Results").pluck("Target")).to eq(%w[layers inputs])
    expect(scanned_files).to include("build.log" => "bounded build log", "image-history.jsonl" => "history line")
    expect(JSON.parse(scanned_files.fetch("image-metadata.json"))).to include("Size" => 10)
  end

  it "fails closed when complete image history exceeds the inspection output limit" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image@sha256:digest")
    runner = lambda do |argv|
      if argv.first(3) == [ "docker", "image", "inspect" ]
        [ JSON.generate([ { "Size" => 10, "Config" => {} } ]), 0, false ]
      else
        [ "retained history prefix", 0, true ]
      end
    end

    expect do
      described_class.new(built_images: built_images, runner: runner).call(image: image, request: request, evidence: evidence)
    end.to raise_error(RuntimeImages::ProviderError, /policy inspection output exceeded/)
  end

  it "rejects an archive whose declared size exceeds the source ceiling before downloading it" do
    blob = instance_double(ActiveStorage::Blob, byte_size: 5)
    allow(attachment).to receive(:blob).and_return(blob)
    allow(source_archive).to receive_messages(attached?: true, attachment: attachment)
    allow(RuntimeImages::Builds::Config).to receive(:max_source_bytes).and_return(4)

    expect(blob).not_to receive(:download)
    expect do
      scanner_with_inputs.call(image: image, request: request, evidence: evidence)
    end.to raise_error(RuntimeImages::Builds::Rejected, /over the 4 byte limit/)
  end

  it "streams source archives with a running cap when blob metadata understates their size" do
    blob = instance_double(ActiveStorage::Blob, byte_size: 1)
    allow(blob).to receive(:download).and_yield("abc").and_yield("def")
    allow(attachment).to receive(:blob).and_return(blob)
    allow(source_archive).to receive_messages(attached?: true, attachment: attachment)
    allow(RuntimeImages::Builds::Config).to receive(:max_source_bytes).and_return(5)

    expect do
      scanner_with_inputs.call(image: image, request: request, evidence: evidence)
    end.to raise_error(RuntimeImages::Builds::Rejected, /archive exceeds the 5 byte limit/)
  end

  it "scans extracted inputs inside a size- and inode-bounded private tmpfs" do
    allow(RuntimeImages::Builds::Config).to receive_messages(max_source_bytes: 1000, max_source_entries: 200_000, build_log_bytes: 50)
    command = nil
    runner = lambda do |argv|
      command = argv if argv.include?(described_class::SCAN_SCRIPT.to_s)
      payload = argv.first(3) == [ "docker", "image", "inspect" ] ? [ { "Config" => {} } ] :
        (argv.first(3) == [ "docker", "image", "history" ] ? "" : { "Results" => [] })
      [ JSON.generate(payload), 0, false ]
    end
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image@sha256:digest")

    described_class.new(built_images: built_images, runner: runner).call(image: image, request: request, evidence: evidence)

    expect(command).to start_with(*described_class::NAMESPACE_PREFIX)
    expect(command).to include(described_class::MOUNT_SCRIPT)
    script_index = command.index(described_class::MOUNT_SCRIPT)
    expect(command.fetch(script_index + 3)).to eq((1000 + (2 * described_class::OUTPUT_LIMIT) + 50).to_s)
    expect(command.fetch(script_index + 4)).to eq("200032")
  end

  def scanner_with_inputs
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image@sha256:digest")
    runner = lambda do |argv|
      payload = argv.first(3) == [ "docker", "image", "inspect" ] ? [ { "Config" => {} } ] :
        (argv.first(3) == [ "docker", "image", "history" ] ? "" : { "Results" => [] })
      [ JSON.generate(payload), 0, false ]
    end
    described_class.new(built_images: built_images, runner: runner)
  end
end
