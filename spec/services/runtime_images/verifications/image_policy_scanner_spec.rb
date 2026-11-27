require "rails_helper"
require "rubygems/package"
require "stringio"

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
      elsif argv[1] == "fs"
        root = argv.last
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

  it "limits extracted source to the remaining aggregate scratch budget" do
    bytes = tar("secret.txt" => "0123456789")
    blob = instance_double(ActiveStorage::Blob, byte_size: bytes.bytesize)
    allow(blob).to receive(:download).and_yield(bytes)
    allow(attachment).to receive(:blob).and_return(blob)
    allow(source_archive).to receive_messages(attached?: true, attachment: attachment)
    allow(RuntimeImages::Builds::Config).to receive(:max_source_bytes).and_return(bytes.bytesize)
    scanner = scanner_with_inputs
    allow(scanner).to receive(:scratch_limit).and_return(bytes.bytesize + 35)

    expect do
      scanner.call(image: image, request: request, evidence: evidence)
    end.to raise_error(RuntimeImages::Builds::Rejected, /source exceeds/)
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

  def tar(files)
    io = StringIO.new
    Gem::Package::TarWriter.new(io) do |writer|
      files.each { |name, body| writer.add_file_simple(name, 0o600, body.bytesize) { |file| file.write(body) } }
    end
    io.string
  end
end
