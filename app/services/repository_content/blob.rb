module RepositoryContent
  # A file's content at a revision. `bytes` is binary (ASCII-8BIT); `size` is
  # the full file size even when `truncated` means `bytes` holds less.
  Blob = Data.define(:path, :bytes, :size, :truncated, :content_id) do
    def initialize(path:, bytes:, size: nil, truncated: false, content_id: nil)
      bytes = bytes.to_s.b
      super(path: path, bytes: bytes, size: size || bytes.bytesize, truncated: truncated, content_id: content_id)
    end

    # UTF-8 text, with invalid sequences replaced. Use `bytes` for binary
    # content -- this is lossy for anything that is not text.
    def text
      bytes.dup.force_encoding(Encoding::UTF_8).scrub("�")
    end
  end
end
