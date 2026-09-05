require "rails_helper"

RSpec.describe K8sCluster::KubeconfigParser do
  # Built from plain Ruby data and serialized with to_yaml, rather than a
  # hand-indented heredoc, so nested user/cluster credential blocks can vary
  # per example without fragile manual YAML indentation.
  def kubeconfig(cluster_overrides: {}, user_attrs:, current_context: "default")
    {
      "current-context" => current_context,
      "clusters" => [
        {
          "name" => "my-cluster",
          "cluster" => {
            "server" => "https://k8s.example.com:6443",
            "certificate-authority-data" => Base64.strict_encode64("ca-cert-pem")
          }.merge(cluster_overrides)
        }
      ],
      "users" => [
        { "name" => "my-user", "user" => user_attrs }
      ],
      "contexts" => [
        { "name" => "default", "context" => { "cluster" => "my-cluster", "user" => "my-user" } }
      ]
    }.to_yaml
  end

  describe "token auth" do
    it "extracts the server URL and bearer token" do
      yaml = kubeconfig(user_attrs: { "token" => "abc123" })

      result = described_class.parse(yaml)

      expect(result.api_server_url).to eq("https://k8s.example.com:6443")
      expect(result.credentials).to eq(
        "token" => "abc123",
        "ca_data" => Base64.strict_encode64("ca-cert-pem")
      )
    end
  end

  describe "client certificate auth" do
    it "extracts the client certificate and key data" do
      cert_data = Base64.strict_encode64("cert-pem")
      key_data = Base64.strict_encode64("key-pem")
      yaml = kubeconfig(user_attrs: { "client-certificate-data" => cert_data, "client-key-data" => key_data })

      result = described_class.parse(yaml)

      expect(result.credentials).to eq(
        "client_cert" => cert_data,
        "client_key" => key_data,
        "ca_data" => Base64.strict_encode64("ca-cert-pem")
      )
    end
  end

  describe "missing/invalid context" do
    it "raises when current-context is not set" do
      yaml = kubeconfig(user_attrs: { "token" => "abc123" }, current_context: "")

      expect { described_class.parse(yaml) }.to raise_error(described_class::ParseError, /current-context/)
    end

    it "raises when current-context does not match any context" do
      yaml = kubeconfig(user_attrs: { "token" => "abc123" }, current_context: "missing")

      expect { described_class.parse(yaml) }.to raise_error(described_class::ParseError, /not found in kubeconfig contexts/)
    end

    it "raises when the referenced cluster is not defined" do
      yaml = <<~YAML
        current-context: default
        clusters: []
        users:
          - name: my-user
            user:
              token: abc123
        contexts:
          - name: default
            context:
              cluster: missing-cluster
              user: my-user
      YAML

      expect { described_class.parse(yaml) }.to raise_error(described_class::ParseError, /missing-cluster.*not defined/)
    end

    it "raises when the referenced user is not defined" do
      yaml = <<~YAML
        current-context: default
        clusters:
          - name: my-cluster
            cluster:
              server: https://k8s.example.com:6443
        users: []
        contexts:
          - name: default
            context:
              cluster: my-cluster
              user: missing-user
      YAML

      expect { described_class.parse(yaml) }.to raise_error(described_class::ParseError, /missing-user.*not defined/)
    end

    it "raises when the cluster has no server URL" do
      yaml = <<~YAML
        current-context: default
        clusters:
          - name: my-cluster
            cluster: {}
        users:
          - name: my-user
            user:
              token: abc123
        contexts:
          - name: default
            context:
              cluster: my-cluster
              user: my-user
      YAML

      expect { described_class.parse(yaml) }.to raise_error(described_class::ParseError, /no server URL/)
    end
  end

  describe "unsupported auth" do
    it "raises a clear error for exec-based credential plugins" do
      yaml = kubeconfig(user_attrs: { "exec" => { "command" => "aws-iam-authenticator" } })

      expect { described_class.parse(yaml) }.to raise_error(described_class::ParseError, /exec-based credential plugin/)
    end

    it "raises a clear error for file-referenced credentials" do
      yaml = kubeconfig(user_attrs: { "client-certificate" => "/home/user/.kube/cert.pem", "client-key" => "/home/user/.kube/key.pem" })

      expect { described_class.parse(yaml) }.to raise_error(described_class::ParseError, /not inline data/)
    end

    it "raises when the user has no recognizable credentials" do
      yaml = kubeconfig(user_attrs: { "username" => "someone" })

      expect { described_class.parse(yaml) }.to raise_error(described_class::ParseError, /no supported credentials/)
    end
  end

  describe "invalid input" do
    it "raises for blank input" do
      expect { described_class.parse("") }.to raise_error(described_class::ParseError, /blank/)
    end

    it "raises for a non-mapping YAML document" do
      expect { described_class.parse("- just\n- a\n- list\n") }.to raise_error(described_class::ParseError, /not a valid kubeconfig/)
    end

    it "raises for syntactically invalid YAML" do
      expect { described_class.parse("current-context: [unterminated") }.to raise_error(described_class::ParseError, /not valid YAML/)
    end
  end
end
