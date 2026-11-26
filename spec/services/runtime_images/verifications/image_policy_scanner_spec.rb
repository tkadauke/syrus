require "rails_helper"

RSpec.describe RuntimeImages::Verifications::ImagePolicyScanner do
  let(:image) { instance_double(RuntimeImage) }
  let(:built_images) { instance_double(RuntimeImages::BuiltImages) }
  let(:source_archive) { instance_double(ActiveStorage::Attached::One, attached?: false) }
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
end
