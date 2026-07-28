require "rails_helper"

RSpec.describe Integrations::Normalizers::TiktokReturnRefundNormalizer do
  def normalize(raw)
    described_class.call(raw)
  end

  it "extracts external_id from order_id" do
    normalized = normalize({ "order_id" => "12345", "return_id" => "r-1" })

    expect(normalized[:external_id]).to eq("12345")
  end

  it "extracts refund_amount from refund_amount.refund_total for a full return/refund" do
    normalized = normalize({
      "order_id" => "12345",
      "refund_amount" => { "currency" => "BRL", "refund_total" => "125.50" }
    })

    expect(normalized[:refund_amount]).to eq(125.50)
  end

  it "falls back to partial_refund.amount when refund_amount is absent (PARTIAL_REFUND shape)" do
    normalized = normalize({
      "order_id" => "12345",
      "seller_proposed_return_type" => "PARTIAL_REFUND",
      "partial_refund" => { "currency" => "BRL", "amount" => "30.00" }
    })

    expect(normalized[:refund_amount]).to eq(30.00)
  end

  it "prefers return_reason_text over the raw return_reason code" do
    normalized = normalize({
      "order_id" => "12345",
      "return_reason" => "SIZE_TOO_SMALL",
      "return_reason_text" => "Tamanho menor que o esperado"
    })

    expect(normalized[:refund_reason]).to eq("Tamanho menor que o esperado")
  end

  it "falls back to the raw return_reason code when no human-readable text is present" do
    normalized = normalize({ "order_id" => "12345", "return_reason" => "SIZE_TOO_SMALL" })

    expect(normalized[:refund_reason]).to eq("SIZE_TOO_SMALL")
  end

  describe "status mapping (return_status -> OrderRefund::STATUSES)" do
    it "maps RETURN_OR_REFUND_REQUEST_SUCCESS to processed" do
      normalized = normalize({ "order_id" => "1", "return_status" => "RETURN_OR_REFUND_REQUEST_SUCCESS" })
      expect(normalized[:status]).to eq("processed")
    end

    it "maps RETURN_OR_REFUND_REQUEST_COMPLETE to processed" do
      normalized = normalize({ "order_id" => "1", "return_status" => "RETURN_OR_REFUND_REQUEST_COMPLETE" })
      expect(normalized[:status]).to eq("processed")
    end

    it "maps RETURN_OR_REFUND_REQUEST_REJECT to ignored" do
      normalized = normalize({ "order_id" => "1", "return_status" => "RETURN_OR_REFUND_REQUEST_REJECT" })
      expect(normalized[:status]).to eq("ignored")
    end

    it "maps RETURN_OR_REFUND_REQUEST_CANCEL to ignored" do
      normalized = normalize({ "order_id" => "1", "return_status" => "RETURN_OR_REFUND_REQUEST_CANCEL" })
      expect(normalized[:status]).to eq("ignored")
    end

    it "maps everything else (pending/in-flight states) to pending" do
      %w[RETURN_OR_REFUND_REQUEST_PENDING AWAITING_BUYER_SHIP BUYER_SHIPPED_ITEM REJECT_RECEIVE_PACKAGE AWAITING_BUYER_RESPONSE].each do |raw_status|
        normalized = normalize({ "order_id" => "1", "return_status" => raw_status })
        expect(normalized[:status]).to eq("pending")
      end
    end
  end

  it "parses create_time (unix seconds) into ordered_at" do
    normalized = normalize({ "order_id" => "1", "create_time" => 1_753_660_800 })

    expect(normalized[:ordered_at]).to eq(Time.zone.at(1_753_660_800))
  end

  it "returns nil ordered_at when create_time is absent" do
    normalized = normalize({ "order_id" => "1" })

    expect(normalized[:ordered_at]).to be_nil
  end

  it "keeps the raw payload and return-level identifiers in metadata for audit" do
    raw = {
      "order_id" => "1", "return_id" => "ret-1", "return_type" => "REFUND",
      "return_status" => "RETURN_OR_REFUND_REQUEST_SUCCESS"
    }
    normalized = normalize(raw)

    expect(normalized[:metadata]).to include(
      "return_id" => "ret-1",
      "return_type" => "REFUND",
      "return_status" => "RETURN_OR_REFUND_REQUEST_SUCCESS",
      "source" => "tiktok_return_refund_api",
      "raw" => raw
    )
  end

  it "does not blow up on a blank/non-hash payload" do
    normalized = normalize(nil)

    expect(normalized[:external_id]).to be_nil
    expect(normalized[:refund_amount]).to eq(0.0)
    expect(normalized[:status]).to eq("pending")
  end
end
