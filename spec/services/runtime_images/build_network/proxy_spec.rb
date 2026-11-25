require "rails_helper"
require "tmpdir"

RSpec.describe RuntimeImages::BuildNetwork::Proxy do
  let(:dir) { Dir.mktmpdir("rib-proxy-spec") }
  let(:socket_path) { File.join(dir, "p.sock") }
  after { FileUtils.rm_rf(dir) }

  # A real upstream on loopback. The resolver is stubbed to answer with a
  # public address and the connector dials this server instead, so the policy
  # and resolver run for real while no traffic leaves the machine.
  let(:upstream) { TCPServer.new("127.0.0.1", 0) }
  let(:dialed) { [] }
  let(:requests) { [] }
  let(:responder) { ->(_request) { "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" } }
  let(:answers) { { "pkg.example.com" => [ "93.184.216.34" ] } }
  let(:resolver) { RuntimeImages::BuildNetwork::Resolver.new(lookup: ->(host) { answers.fetch(host, []) }) }
  let(:rules) do
    [ RuntimeImages::BuildNetwork::Policy::Rule.new(source_class: "exact_domain", host: "pkg.example.com", port: 80, path_prefix: "", ecosystem: "", required: false),
      RuntimeImages::BuildNetwork::Policy::Rule.new(source_class: "exact_domain", host: "pkg.example.com", port: 443, path_prefix: "", ecosystem: "", required: false),
      RuntimeImages::BuildNetwork::Policy::Rule.new(source_class: "repository_namespace", host: "git.example.com", port: 80, path_prefix: "/acme/", ecosystem: "", required: false) ]
  end
  let(:policy) { RuntimeImages::BuildNetwork::Policy.new(rules) }
  let(:proxy) do
    port = upstream.addr[1]
    connector = lambda do |address, p|
      dialed << [ address, p ]
      TCPSocket.new("127.0.0.1", port)
    end
    described_class.new(policy: policy, socket_path: socket_path, resolver: resolver, connector: connector, idle_timeout: 2).start
  end
  let!(:server) do
    Thread.new do
      loop do
        conn = upstream.accept
        Thread.new(conn) do |c|
          head = +""
          head << c.readpartial(4096) until head.include?("\r\n\r\n")
          requests << head
          if head.start_with?("CONNECT") || head.empty?
            c.write("tunnel-ready")
          else
            c.write(responder.call(head))
          end
          c.close
        rescue EOFError, SystemCallError
          c.close
        end
      rescue IOError
        break
      end
    end
  end
  before { proxy }
  after do
    proxy.stop
    upstream.close
    server.kill
  end

  def request(raw)
    sock = UNIXSocket.new(socket_path)
    sock.write(raw)
    sock.close_write
    sock.read
  ensure
    sock&.close
  end

  def status(response) = response[%r{\AHTTP/1\.\d (\d{3})}, 1].to_i

  describe "plain HTTP" do
    it "forwards an allowlisted request in origin form with a canonical Host and no proxy headers" do
      response = request("GET http://pkg.example.com/pool/a.deb HTTP/1.1\r\nHost: evil.example\r\nProxy-Authorization: x\r\nUser-Agent: apt\r\n\r\n")
      expect(status(response)).to eq(200)
      expect(response).to end_with("ok")
      sent = requests.first
      expect(sent).to start_with("GET /pool/a.deb HTTP/1.1\r\nHost: pkg.example.com\r\n")
      expect(sent).to include("User-Agent: apt")
      expect(sent).not_to match(/evil\.example|Proxy-Authorization/i)
      expect(dialed).to eq([ [ "93.184.216.34", 80 ] ])
      expect(proxy.summary).to include("allowed" => 1, "denied" => 0)
    end

    it "denies hosts that are not allowlisted and never dials them" do
      response = request("GET http://other.example.com/ HTTP/1.1\r\n\r\n")
      expect(status(response)).to eq(403)
      expect(response).to include("X-Build-Network-Denied: not_allowlisted")
      expect(dialed).to be_empty
      expect(proxy.summary["denials"]).to eq([ { "host" => "other.example.com", "port" => 80, "reason" => "not_allowlisted", "count" => 1 } ])
    end

    it "denies literal-IP destinations" do
      %w[127.0.0.1 169.254.169.254 2130706433 0x7f.1].each do |ip|
        response = request("GET http://#{ip}/ HTTP/1.1\r\n\r\n")
        expect(response).to include("X-Build-Network-Denied: literal_ip_forbidden"), ip
      end
      expect(dialed).to be_empty
    end

    it "rejects userinfo tricks, origin-form requests, and https absolute URIs" do
      expect(status(request("GET http://pkg.example.com@evil.example/ HTTP/1.1\r\n\r\n"))).to eq(400)
      expect(status(request("GET /path HTTP/1.1\r\nHost: pkg.example.com\r\n\r\n"))).to eq(400)
      expect(status(request("GET https://pkg.example.com/ HTTP/1.1\r\n\r\n"))).to eq(400)
    end

    it "rejects header injection and chunked request bodies" do
      expect(status(request("GET http://pkg.example.com/ HTTP/1.1\r\nX-A: b\nX-Evil: 1\r\n\r\n"))).to eq(400)
      expect(status(request("POST http://pkg.example.com/ HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))).to eq(501)
      expect(dialed).to be_empty
    end

    it "forwards a request body with its declared length" do
      response = request("POST http://pkg.example.com/up HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")
      expect(status(response)).to eq(200)
      expect(requests.first).to include("Content-Length: 5")
    end

    it "enforces repository namespaces by path and refuses traversal out of them" do
      answers["git.example.com"] = [ "93.184.216.35" ]
      expect(status(request("GET http://git.example.com/acme/x.git/info/refs HTTP/1.1\r\n\r\n"))).to eq(200)
      expect(status(request("GET http://git.example.com/other/x.git HTTP/1.1\r\n\r\n"))).to eq(403)
      expect(status(request("GET http://git.example.com/acme/%2e%2e/other HTTP/1.1\r\n\r\n"))).to eq(403)
    end

    context "when upstream redirects" do
      let(:responder) { ->(_r) { "HTTP/1.1 302 Found\r\nLocation: #{location}\r\nContent-Length: 0\r\n\r\n" } }

      context "to an unauthorized host" do
        let(:location) { "http://evil.example.net/payload" }

        it "replaces the redirect with a denial so the client never learns the target" do
          response = request("GET http://pkg.example.com/r HTTP/1.1\r\n\r\n")
          expect(status(response)).to eq(403)
          expect(response).to include("redirect_not_allowlisted")
          expect(response).not_to include("evil.example.net/payload")
        end

        it "blocks a protocol-relative and a link-local redirect too" do
          %w[//evil.example.net/x http://169.254.169.254/latest/meta-data/].each do |loc|
            responder_with(loc)
            expect(status(request("GET http://pkg.example.com/r HTTP/1.1\r\n\r\n"))).to eq(403), loc
          end
        end
      end

      context "to an allowlisted host" do
        let(:location) { "http://pkg.example.com/other" }

        it "passes the redirect to the client, which must come back through the proxy" do
          response = request("GET http://pkg.example.com/r HTTP/1.1\r\n\r\n")
          expect(status(response)).to eq(302)
          expect(response).to include("Location: http://pkg.example.com/other")
        end
      end
    end

    def responder_with(location)
      allow(self).to receive(:responder).and_return(->(_r) { "HTTP/1.1 301 Moved\r\nLocation: #{location}\r\nContent-Length: 0\r\n\r\n" })
    end
  end

  describe "CONNECT" do
    it "tunnels to an allowlisted host:port" do
      sock = UNIXSocket.new(socket_path)
      sock.write("CONNECT pkg.example.com:443 HTTP/1.1\r\nHost: pkg.example.com:443\r\n\r\n")
      expect(sock.readpartial(200)).to start_with("HTTP/1.1 200 Connection Established")
      sock.write("CONNECT pkg.example.com:443 HTTP/1.1\r\n\r\n")
      expect(sock.readpartial(200)).to eq("tunnel-ready")
      expect(dialed).to eq([ [ "93.184.216.34", 443 ] ])
    ensure
      sock&.close
    end

    {
      "unlisted port" => "CONNECT pkg.example.com:8443 HTTP/1.1\r\n\r\n",
      "unlisted host" => "CONNECT other.example.com:443 HTTP/1.1\r\n\r\n",
      "literal ip" => "CONNECT 169.254.169.254:80 HTTP/1.1\r\n\r\n",
      "ipv6 literal" => "CONNECT [::1]:443 HTTP/1.1\r\n\r\n",
      "decimal ip" => "CONNECT 2130706433:80 HTTP/1.1\r\n\r\n",
      "path-scoped namespace" => "CONNECT git.example.com:80 HTTP/1.1\r\n\r\n"
    }.each do |label, raw|
      it "denies #{label}" do
        expect(status(request(raw))).to eq(403)
        expect(dialed).to be_empty
      end
    end

    it "denies a name that resolves to a private or metadata address (DNS rebinding)" do
      answers["pkg.example.com"] = [ "169.254.169.254" ]
      response = request("CONNECT pkg.example.com:443 HTTP/1.1\r\n\r\n")
      expect(response).to include("destination_address_forbidden")
      answers["pkg.example.com"] = [ "93.184.216.34", "10.0.0.5" ]
      expect(request("CONNECT pkg.example.com:443 HTTP/1.1\r\n\r\n")).to include("destination_address_forbidden")
      expect(dialed).to be_empty
    end

    it "dials the address it validated, not the name, even if the name later re-binds" do
      sock = UNIXSocket.new(socket_path)
      sock.write("CONNECT pkg.example.com:443 HTTP/1.1\r\n\r\n")
      sock.readpartial(200)
      answers["pkg.example.com"] = [ "127.0.0.1" ]
      expect(dialed.map(&:first)).to eq([ "93.184.216.34" ])
    ensure
      sock&.close
    end

    it "rejects malformed targets" do
      expect(status(request("CONNECT pkg.example.com HTTP/1.1\r\n\r\n"))).to eq(400)
      expect(status(request("CONNECT pkg.example.com:abc HTTP/1.1\r\n\r\n"))).to eq(400)
    end
  end

  it "refuses connections beyond its cap" do
    small = described_class.new(policy: policy, socket_path: File.join(dir, "s.sock"), resolver: resolver, max_connections: 1, idle_timeout: 2).start
    held = UNIXSocket.new(File.join(dir, "s.sock"))
    sleep 0.1
    second = UNIXSocket.new(File.join(dir, "s.sock"))
    expect(second.read).to include("proxy_busy")
  ensure
    held&.close
    second&.close
    small&.stop
  end

  it "answers a stalled client with a timeout instead of hanging" do
    stub_const("#{described_class}::HEAD_TIMEOUT", 0.2)
    sock = UNIXSocket.new(socket_path)
    sock.write("GET http://pkg.example.com/ HTTP/1.1\r\n")
    expect(sock.read).to include("head_timeout")
  ensure
    sock&.close
  end

  it "removes its socket on stop" do
    proxy.stop
    expect(File.exist?(socket_path)).to be(false)
  end
end
