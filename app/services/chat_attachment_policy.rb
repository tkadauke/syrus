class ChatAttachmentPolicy
  CONFIG = JSON.parse(Rails.root.join("config/chat_attachment_policy.json").read).freeze
  BINARY_EXTENSIONS = CONFIG.fetch("binary_extensions").freeze
  TEXT_EXTENSIONS = CONFIG.fetch("text_extensions").freeze
  TEXT_FILENAMES = CONFIG.fetch("text_filenames").freeze
  TEXT_APPLICATION_MIME_TYPES = CONFIG.fetch("text_application_mime_types").freeze
  FALLBACK_MIME_TYPES = CONFIG.fetch("fallback_mime_types").freeze

  Result = Data.define(:accepted?, :text?, :extension, :mime_type)

  def self.check(filename:, mime_type:)
    new(filename:, mime_type:).check
  end

  def self.sanitize_filename(name)
    basename = File.basename(name.to_s.tr("\\", "/"))
    basename = basename.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "_")
    basename = basename.gsub(/[\u0000-\u001f\u007f]/, "_").gsub(/[^\p{Alnum}._+@() -]/, "_").strip
    basename = "attachment" if basename.blank? || basename.in?([ ".", ".." ])
    basename.first(180)
  end

  def self.valid_text?(bytes)
    return false if bytes.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/n)

    bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
  end

  def initialize(filename:, mime_type:)
    @filename = self.class.sanitize_filename(filename)
    @mime_type = mime_type.to_s.downcase.split(";", 2).first.to_s.strip
  end

  def check
    extension = File.extname(@filename).downcase
    binary_mimes = BINARY_EXTENSIONS[extension]
    return Result.new(accepted?: binary_mimes.include?(@mime_type), text?: false, extension:, mime_type: @mime_type) if binary_mimes

    recognized_text = TEXT_EXTENSIONS.include?(extension) || (extension.empty? && TEXT_FILENAMES.include?(@filename))
    accepted = recognized_text && compatible_text_mime?
    Result.new(accepted?: accepted, text?: recognized_text, extension:, mime_type: @mime_type)
  end

  private

  def compatible_text_mime?
    @mime_type.start_with?("text/") || TEXT_APPLICATION_MIME_TYPES.include?(@mime_type) || FALLBACK_MIME_TYPES.include?(@mime_type)
  end
end
