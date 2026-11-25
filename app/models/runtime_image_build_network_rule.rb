# One administrator-declared build-network destination. Builds can reach a
# host only if an enabled rule here names it; see RuntimeImages::BuildNetwork.
class RuntimeImageBuildNetworkRule < ApplicationRecord
  PORTS = (1..65_535)

  attribute :path_prefix, :string, default: ""
  attribute :ecosystem, :string, default: ""

  before_validation :normalize

  validates :source_class, inclusion: { in: ->(_) { RuntimeImages::BuildNetwork::SourceClass.keys } }
  validates :host, presence: true
  validates :port, inclusion: { in: PORTS }
  validates :host, uniqueness: { scope: %i[source_class port path_prefix] }
  validate :valid_for_source_class

  scope :enabled, -> { where(enabled: true) }

  def source
    RuntimeImages::BuildNetwork::SourceClass.for(source_class)
  end

  private

  def normalize
    self.path_prefix = path_prefix.to_s.strip
    self.ecosystem = ecosystem.to_s.strip.downcase
    return if host.blank?

    canonical = RuntimeImages::BuildNetwork::HostName.normalize(host)
    self.host = canonical if canonical
  end

  def valid_for_source_class
    return unless RuntimeImages::BuildNetwork::SourceClass.key?(source_class)

    errors.add(:host, :not_a_dns_host_name) if host.present? && RuntimeImages::BuildNetwork::HostName.normalize(host).nil?
    source.validate(self).each { |message| errors.add(:base, message) }
  end
end
