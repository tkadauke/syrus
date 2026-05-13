class JobAttachment < ApplicationRecord
  belongs_to :job

  has_one_attached :file

  validates :source_url, presence: true, uniqueness: { scope: :job_id }
  validates :filename, :content_type, presence: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
end
