# This file seeds the database with demo data for testing Imprint instrumentation

puts "Seeding database..."

# Clear existing data
Order.destroy_all
Product.destroy_all

# Product categories and sample data
categories = ["Electronics", "Clothing", "Home & Garden", "Sports", "Books"]

adjectives = [
  "Premium", "Deluxe", "Essential", "Classic", "Modern",
  "Professional", "Compact", "Wireless", "Organic", "Vintage"
]

nouns = {
  "Electronics" => ["Headphones", "Speaker", "Charger", "Cable", "Mouse", "Keyboard", "Monitor Stand", "USB Hub", "Webcam", "Microphone"],
  "Clothing" => ["T-Shirt", "Hoodie", "Jacket", "Pants", "Shorts", "Cap", "Socks", "Sneakers", "Belt", "Scarf"],
  "Home & Garden" => ["Lamp", "Planter", "Cushion", "Rug", "Vase", "Clock", "Frame", "Candle", "Basket", "Mirror"],
  "Sports" => ["Water Bottle", "Yoga Mat", "Resistance Band", "Dumbbell", "Jump Rope", "Towel", "Bag", "Gloves", "Socks", "Timer"],
  "Books" => ["Notebook", "Journal", "Planner", "Sketchbook", "Guide", "Manual", "Cookbook", "Novel", "Biography", "Textbook"]
}

# Generate 50 products
50.times do |i|
  category = categories.sample
  adjective = adjectives.sample
  noun = nouns[category].sample

  Product.create!(
    name: "#{adjective} #{noun}",
    sku: "SKU-#{category[0..2].upcase}-#{1000 + i}",
    description: "High-quality #{noun.downcase} for everyday use. Perfect for anyone looking for a reliable #{category.downcase} product.",
    price: rand(9.99..299.99).round(2),
    stock: rand(0..100),
    category: category
  )
end

puts "Created #{Product.count} products"

# Create a few sample orders
3.times do |i|
  order = Order.create!(
    email: "customer#{i + 1}@example.com",
    total: rand(50..500).round(2),
    status: %w[pending processed shipped].sample,
    items: Product.order("RANDOM()").limit(rand(1..4)).pluck(:id).map { |id| { product_id: id, quantity: rand(1..3) } }.to_json
  )
  puts "Created order ##{order.id}"
end

puts "Seeding complete!"
puts ""
puts "Test the app:"
puts "  1. Start the server:  bin/rails server -p 3000"
puts "  2. Start the worker:  bin/rails jobs:work"
puts "  3. Visit:             http://localhost:3000/shop"
puts ""
puts "Scenarios:"
puts "  GET  /products  - List products (SQL + View tracing)"
puts "  POST /checkout  - Create order (Job trace propagation)"
puts "  GET  /crash     - Trigger error (Error recording)"
