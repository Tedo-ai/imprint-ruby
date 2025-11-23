class Product < ApplicationRecord
  validates :name, presence: true
  validates :price, presence: true, numericality: { greater_than: 0 }
  validates :sku, presence: true, uniqueness: true

  scope :in_stock, -> { where("stock > 0") }
  scope :by_category, ->(cat) { where(category: cat) }

  def formatted_price
    "$#{format('%.2f', price)}"
  end
end
