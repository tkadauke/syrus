require "rails_helper"

RSpec.describe ChatAttachmentPolicy do
  it "accepts every configured text extension with browser fallback MIME types" do
    described_class::TEXT_EXTENSIONS.each do |extension|
      expect(described_class.check(filename: "sample#{extension}", mime_type: "text/plain")).to be_accepted, extension
      expect(described_class.check(filename: "sample#{extension}", mime_type: "application/octet-stream")).to be_accepted, extension
    end
  end

  it "accepts recognized extensionless filenames and configured raster/PDF pairs" do
    described_class::TEXT_FILENAMES.each do |filename|
      expect(described_class.check(filename: filename, mime_type: "text/plain")).to be_accepted, filename
    end

    described_class::BINARY_EXTENSIONS.each do |extension, mime_types|
      mime_types.each do |mime_type|
        expect(described_class.check(filename: "sample#{extension}", mime_type: mime_type)).to be_accepted
      end
    end
  end

  it "accepts ZIP archives for the MIME types browsers commonly supply" do
    %w[application/zip application/x-zip-compressed application/octet-stream binary/octet-stream].each do |mime_type|
      result = described_class.check(filename: "archive.ZIP", mime_type: mime_type)
      expect(result).to be_accepted, mime_type
      expect(result.text?).to be(false)
    end
    expect(described_class.check(filename: "archive.zip", mime_type: "text/plain")).not_to be_accepted
  end

  it "rejects binary, executable, archive, Office, media, font, disk-image, unknown, and MIME-mismatched files" do
    %w[program.exe archive.tar.gz archive.7z archive.rar document.docx song.mp3 movie.mp4 font.woff disk.iso disk.dmg unknown.bin].each do |filename|
      expect(described_class.check(filename: filename, mime_type: "application/octet-stream")).not_to be_accepted, filename
    end

    expect(described_class.check(filename: "source.rb", mime_type: "image/png")).not_to be_accepted
    expect(described_class.check(filename: "image.png", mime_type: "text/plain")).not_to be_accepted
  end

  it "recognizes only NUL-free valid UTF-8 without binary control bytes as text" do
    expect(described_class.valid_text?("hello\nworld".b)).to be(true)
    expect(described_class.valid_text?("nul\0byte".b)).to be(false)
    expect(described_class.valid_text?("control\x01byte".b)).to be(false)
    expect(described_class.valid_text?("invalid\xFF".b)).to be(false)
  end
end
