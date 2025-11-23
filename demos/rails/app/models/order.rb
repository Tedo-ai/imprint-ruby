class Order < ApplicationRecord
  validates :email, presence: true
  validates :total, presence: true, numericality: { greater_than: 0 }

  enum :status, {
    pending: "pending",
    processing: "processing",
    processed: "processed",
    shipped: "shipped",
    failed: "failed"
  }

  scope :recent, -> { order(created_at: :desc).limit(10) }

  def process!
    update!(status: :processed, processed_at: Time.current)
  end
end
