class KubernetesCluster < ApplicationRecord
  attribute :credentials, :json
  attribute :agentic_access_enabled, :boolean, default: false
  attribute :allow_writes, :boolean, default: false
  attribute :insecure_skip_tls_verify, :boolean, default: false
  encrypts :credentials

  after_initialize :seed_credentials

  validates :label, presence: true
  validates :api_server_url, presence: true

  def token
    credentials.to_h["token"]
  end

  def token=(value)
    self.credentials = credentials.to_h.merge("token" => value)
  end

  def client_cert
    credentials.to_h["client_cert"]
  end

  def client_cert=(value)
    self.credentials = credentials.to_h.merge("client_cert" => value)
  end

  def client_key
    credentials.to_h["client_key"]
  end

  def client_key=(value)
    self.credentials = credentials.to_h.merge("client_key" => value)
  end

  def ca_data
    credentials.to_h["ca_data"]
  end

  def ca_data=(value)
    self.credentials = credentials.to_h.merge("ca_data" => value)
  end

  private

  def seed_credentials
    self.credentials ||= {}
  end
end
