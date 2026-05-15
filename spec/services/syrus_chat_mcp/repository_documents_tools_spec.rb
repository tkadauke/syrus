require "rails_helper"

RSpec.describe "SyrusChatMcp repository document tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::ListRepoDocumentsTool,
        SyrusChatMcp::ReadRepoDocumentTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def upload(filename:, content_type:, content:)
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      content_type,
      original_filename: filename
    )
  end

  def text_content(response)
    response.dig(:result, :content, 0, :text)
  end

  def pdf_with_text(text)
    objects = []
    objects << "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
    objects << "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
    objects << "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n"
    objects << "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"
    stream = "BT /F1 24 Tf 100 700 Td (#{text}) Tj ET"
    objects << "5 0 obj\n<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream\nendobj\n"

    pdf = "%PDF-1.4\n"
    offsets = [ 0 ]
    objects.each do |object|
      offsets << pdf.bytesize
      pdf << object
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
    offsets[1..].each { |offset| pdf << "%010d 00000 n \n" % offset }
    pdf << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    pdf
  end

  it "lists file and Google Doc documents for the chat repository" do
    file_document = repository.repository_documents.create!(
      user: user,
      kind: "file",
      title: "API spec",
      file: upload(filename: "api.md", content_type: "text/markdown", content: "# API")
    )
    google_document = repository.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Architecture notes",
      google_docs_url: "https://docs.google.com/document/d/abc/edit"
    )

    response = call_tool("list_repo_documents")
    payload = JSON.parse(text_content(response), symbolize_names: true)

    expect(payload).to eq([
      {
        id: file_document.id,
        kind: "file",
        title: "API spec",
        content_type: "text/markdown",
        size_bytes: 5
      },
      {
        id: google_document.id,
        kind: "google_doc",
        title: "Architecture notes",
        url: "https://docs.google.com/document/d/abc/edit"
      }
    ])
  end

  it "includes documents reachable through attached jobs" do
    other = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: other)
    document = other.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Job context",
      google_docs_url: "https://docs.google.com/document/d/job/edit"
    )
    chat_session.chat_attachments.create!(attachable: job)

    response = call_tool("list_repo_documents")
    payload = JSON.parse(text_content(response), symbolize_names: true)

    expect(payload).to include(
      id: document.id,
      kind: "google_doc",
      title: "Job context",
      url: "https://docs.google.com/document/d/job/edit"
    )
  end

  it "rejects reads outside the chat attachment scope" do
    other = Factories.repository(user: user)
    document = other.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Elsewhere",
      google_docs_url: "https://docs.google.com/document/d/other/edit"
    )

    response = call_tool("read_repo_document", id: document.id)

    expect(response.dig(:result, :isError)).to be true
    expect(text_content(response)).to include("document not found in this chat session's attachments")
  end

  it "returns text file content and caps large documents at 64 KB" do
    document = repository.repository_documents.create!(
      user: user,
      kind: "file",
      title: "Large notes",
      file: upload(filename: "large.txt", content_type: "text/plain", content: "x" * 70.kilobytes)
    )

    response = call_tool("read_repo_document", id: document.id)
    text = text_content(response)

    expect(text.bytesize).to eq(64.kilobytes)
    expect(text).to include("[Document truncated after 65536 bytes; omitted 6144 bytes.]")
  end

  it "returns image files as MCP image content blocks" do
    png = "\x89PNG\r\n\x1A\n".b
    document = repository.repository_documents.create!(
      user: user,
      kind: "file",
      title: "Screenshot",
      file: upload(filename: "screen.png", content_type: "image/png", content: png)
    )

    response = call_tool("read_repo_document", id: document.id)
    block = response.dig(:result, :content, 0)

    expect(block).to include(type: "image", mimeType: "image/png")
    expect(Base64.decode64(block[:data])).to eq(png)
  end

  it "extracts PDF text" do
    document = repository.repository_documents.create!(
      user: user,
      kind: "file",
      title: "API PDF",
      file: upload(filename: "api.pdf", content_type: "application/pdf", content: pdf_with_text("Hello PDF"))
    )

    response = call_tool("read_repo_document", id: document.id)

    expect(text_content(response)).to include("Hello PDF")
  end

  it "fetches Google Doc text and caches it for one hour" do
    document = repository.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Architecture",
      google_docs_url: "https://docs.google.com/document/d/abc/edit"
    )
    export_url = "https://docs.google.com/document/d/abc/export?format=txt"
    stub = stub_request(:get, export_url).to_return(status: 200, body: "Fresh notes")

    first = call_tool("read_repo_document", id: document.id)
    second = call_tool("read_repo_document", id: document.id)

    expect(text_content(first)).to eq("Fresh notes")
    expect(text_content(second)).to eq("Fresh notes")
    expect(stub).to have_been_requested.once
    expect(document.reload.content_cache).to eq("Fresh notes")
    expect(document.content_cached_at).to be_within(5.seconds).of(Time.current)
  end

  it "uses fresh Google Doc cache entries without fetching" do
    document = repository.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Architecture",
      google_docs_url: "https://docs.google.com/document/d/abc/edit",
      content_cache: "Cached notes",
      content_cached_at: 30.minutes.ago
    )

    response = call_tool("read_repo_document", id: document.id)

    expect(text_content(response)).to eq("Cached notes")
    expect(a_request(:get, "https://docs.google.com/document/d/abc/export?format=txt")).not_to have_been_made
  end

  it "refetches expired Google Doc cache entries" do
    document = repository.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Architecture",
      google_docs_url: "https://docs.google.com/document/d/abc/edit",
      content_cache: "Old notes",
      content_cached_at: 2.hours.ago
    )
    stub_request(:get, "https://docs.google.com/document/d/abc/export?format=txt")
      .to_return(status: 200, body: "New notes")

    response = call_tool("read_repo_document", id: document.id)

    expect(text_content(response)).to eq("New notes")
    expect(document.reload.content_cache).to eq("New notes")
  end

  it "returns a tool error when Google Doc export fails" do
    document = repository.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Private Architecture",
      google_docs_url: "https://docs.google.com/document/d/private/edit"
    )
    stub_request(:get, "https://docs.google.com/document/d/private/export?format=txt")
      .to_return(status: 403, body: "nope")

    response = call_tool("read_repo_document", id: document.id)

    expect(response.dig(:result, :isError)).to be true
    expect(text_content(response)).to include("Could not fetch Google Doc text")
    expect(text_content(response)).to include("shared publicly or with anyone who has the link")
  end
end
