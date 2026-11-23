require "rails_helper"

RSpec.describe GoogleWorkspace::MailAdapter do
  MailAccount = Data.define(:provider, :id) unless const_defined?(:MailAccount)
  MailAccess = Data.define(:authorization_header) unless const_defined?(:MailAccess)
  let(:account) { MailAccount.new(provider: "google_workspace", id: 23) }
  let(:access) { MailAccess.new(authorization_header: "Bearer secret-access-token") }
  let(:arguments) { { "query" => 'invoice" OR from:attacker@example.test', "limit" => 2, "message_id" => "message/1" } }
  let(:context) { SyrusMail::Context.new(account:, access:, arguments:) }

  def encoded(value, encoding: "UTF-8")
    Base64.urlsafe_encode64(value.encode(encoding), padding: false)
  end

  def message_payload(parts:, id: "message-1", headers: nil)
    {
      id:, threadId: "thread-1", labelIds: %w[INBOX IMPORTANT], snippet: "A short snippet",
      payload: { headers: headers || [
        { name: "From", value: "Sender <sender@example.test>" }, { name: "To", value: "one@example.test" },
        { name: "Cc", value: "two@example.test" }, { name: "Subject", value: "Subject" },
        { name: "Date", value: "Sun, 22 Nov 2026 10:00:00 +0000" }
      ], parts: }
    }.to_json
  end

  it "searches for one escaped literal and normalizes message metadata" do
    search = stub_request(:get, %r{gmail.googleapis.com/gmail/v1/users/me/messages\?})
      .with { |request|
        query = Rack::Utils.parse_query(request.uri.query)
        query["q"] == '"invoice\\" OR from:attacker@example.test"' && query["maxResults"] == "2"
      }.to_return(status: 200, body: { messages: [ { id: "message-1" } ] }.to_json)
    stub_request(:get, %r{/gmail/v1/users/me/messages/message-1\?}).to_return(status: 200, body: message_payload(parts: []))

    message = described_class.search(context).fetch("messages").sole

    expect(search).to have_been_requested
    expect(message).to include("id" => "message-1", "thread_id" => "thread-1", "sender" => "Sender <sender@example.test>",
      "recipients" => "one@example.test, two@example.test", "subject" => "Subject", "labels" => %w[INBOX IMPORTANT])
    expect(WebMock::RequestRegistry.instance.requested_signatures.to_s).not_to include("secret-access-token")
  end

  it "normalizes header names case-insensitively and preserves repeated recipients" do
    headers = [
      { name: "from", value: "Sender <sender@example.test>" }, { name: "TO", value: "one@example.test" },
      { name: "to", value: "two@example.test" }, { name: "Cc", value: "three@example.test" },
      { name: "subject", value: "Lowercase subject" }, { name: "DATE", value: "Sun, 22 Nov 2026 10:00:00 +0000" }
    ]
    stub_request(:get, %r{/gmail/v1/users/me/messages/message%2F1\?})
      .to_return(status: 200, body: message_payload(parts: [], headers:))

    result = described_class.read_message(context)

    expect(result).to include(
      "sender" => "Sender <sender@example.test>",
      "recipients" => "one@example.test, two@example.test, three@example.test",
      "subject" => "Lowercase subject",
      "date" => "Sun, 22 Nov 2026 10:00:00 +0000"
    )
  end

  it "prefers multipart plain text, converts charsets, and lists attachments without fetching them" do
    parts = [
      { mimeType: "text/plain; charset=ISO-8859-1", body: { data: encoded("Grüße", encoding: "ISO-8859-1"), size: 5 } },
      { mimeType: "text/html; charset=UTF-8", body: { data: encoded("<p>ignored html</p>"), size: 19 } },
      { mimeType: "application/pdf", filename: "invoice.pdf", body: { attachmentId: "never-fetch-this", size: 4312 } }
    ]
    stub_request(:get, %r{/gmail/v1/users/me/messages/message%2F1\?}).to_return(status: 200, body: message_payload(parts:))

    result = described_class.read_message(context)

    expect(result["body"]).to eq("Grüße")
    expect(result["attachments"]).to eq([ { "filename" => "invoice.pdf", "content_type" => "application/pdf", "size" => 4312 } ])
    expect(a_request(:get, /attachments/)).not_to have_been_made
  end

  it "turns HTML-only mail into plain text" do
    parts = [ { mimeType: "text/html; charset=UTF-8", body: { data: encoded("<style>x{}</style><p>Hello &amp; goodbye</p>"), size: 45 } } ]
    stub_request(:get, %r{/gmail/v1/users/me/messages/message%2F1\?}).to_return(status: 200, body: message_payload(parts:))
    expect(described_class.read_message(context).fetch("body")).to eq("Hello & goodbye")
  end

  it "bounds oversized decoded bodies" do
    body = "a" * (described_class::MAX_BODY_BYTES + 10)
    stub_request(:get, %r{/gmail/v1/users/me/messages/message%2F1\?}).to_return(status: 200,
      body: message_payload(parts: [ { mimeType: "text/plain", body: { data: encoded(body), size: body.bytesize } } ]))
    result = described_class.read_message(context).fetch("body")
    expect(result.bytesize).to be <= described_class::MAX_BODY_BYTES + 30
    expect(result).to end_with("[Message body truncated]")
  end

  it "maps quota responses to a typed problem without leaking credentials" do
    stub_request(:get, %r{gmail.googleapis.com/gmail/v1/}).to_return(status: 429, headers: { "Retry-After" => "30" }, body: "quota")
    expect { described_class.read_message(context) }.to raise_error(GoogleWorkspace::MailProblem) { |error|
      expect(error.code).to eq("quota_limited")
      expect(error.retry_after).to eq("30")
      expect(error.message).not_to include("secret-access-token")
    }
  end

  it "marks a revoked grant as needing reauthorization" do
    stub_request(:get, %r{gmail.googleapis.com/gmail/v1/}).to_return(status: 401, body: "revoked")
    allow(ConnectedAccounts::OauthBroker).to receive(:needs_reauth!).with(account)
    expect { described_class.read_message(context) }.to raise_error(GoogleWorkspace::MailProblem) { |error|
      expect(error.code).to eq("needs_reauth")
    }
    expect(ConnectedAccounts::OauthBroker).to have_received(:needs_reauth!).with(account)
  end
end
