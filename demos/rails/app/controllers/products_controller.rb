class ProductsController < ApplicationController
  # GET /products
  # Tests: sql.active_record (SELECT), render_template.action_view
  def index
    # Set a custom action name for better trace identification
    Imprint.set_action("ProductsController#index")
    Imprint.tag(endpoint: "storefront", feature: "product_listing")

    # Simulate realistic database queries
    @products = Product.all.order(created_at: :desc)
    @total_count = Product.count
    @in_stock_count = Product.in_stock.count
    @categories = Product.distinct.pluck(:category).compact

    # Log for debugging
    Imprint.record_event("products.loaded", attributes: {
      total: @total_count,
      in_stock: @in_stock_count
    })

    respond_to do |format|
      format.html # renders index.html.erb
      format.json { render json: @products }
    end
  end
end
