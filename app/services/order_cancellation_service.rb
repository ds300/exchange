class OrderCancellationService
  def initialize(order, user_id = nil)
    @order = order
    @user_id = user_id
    @transaction = nil
  end

  def seller_lapse!
    @order.seller_lapse! do
      process_stripe_refund if @order.mode == Order::BUY
    end
    process_inventory_undeduction
    OrderEvent.delay_post(@order, Order::CANCELED)
  ensure
    @order.transactions << @transaction if @transaction.present?
  end

  def buyer_lapse!
    @order.buyer_lapse!
    OrderEvent.delay_post(@order, Order::CANCELED)
  end

  def reject!(rejection_reason = nil)
    @order.reject!(rejection_reason) do
      process_stripe_refund if @order.mode == Order::BUY
    end
    Exchange.dogstatsd.increment 'order.reject'
    process_inventory_undeduction
    OrderEvent.delay_post(@order, Order::CANCELED, @user_id)
  ensure
    @order.transactions << @transaction if @transaction.present?
  end

  def refund!
    @order.refund! do
      process_stripe_refund
    end
    record_stats
    process_inventory_undeduction
    OrderEvent.delay_post(@order, Order::REFUNDED, @user_id)
  ensure
    @order.transactions << @transaction if @transaction.present?
  end

  private

  def process_inventory_undeduction
    @order.line_items.each { |li| UndeductLineItemInventoryJob.perform_later(li.id) }
  end

  def process_stripe_refund
    @transaction = PaymentService.refund_charge(@order.external_charge_id)
    raise Errors::ProcessingError.new(:refund_failed, @transaction.failure_data) if @transaction.failed?
  end

  def record_stats
    Exchange.dogstatsd.increment 'order.refund'
    Exchange.dogstatsd.count('order.money_refunded', @order.buyer_total_cents)
  end
end
