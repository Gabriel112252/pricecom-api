require "rails_helper"

# Fixture confirmada via chamada real de produção (tenant Hidrabene,
# 2026-07-28) contra return_refund/202309/returns/search — substitui a
# suposição anterior baseada no SDK de terceiros github.com/hsib19/
# tiktok-shop-sdk (cujo campo `partial_refund` nunca apareceu na resposta
# real). Ver spec/fixtures/integrations/tiktok_returns.json.
RSpec.describe Integrations::Normalizers::TiktokReturnRefundNormalizer do
  let(:returns_fixture) { JSON.parse(File.read(Rails.root.join("spec/fixtures/integrations/tiktok_returns.json"))) }
  let(:return_orders) { returns_fixture.dig("data", "return_orders") }
  let(:pending_refund) { return_orders.first } # return_type REFUND, return_status RETURN_OR_REFUND_REQUEST_PENDING
  let(:shipped_return_and_refund) { return_orders.second } # return_type RETURN_AND_REFUND, return_status BUYER_SHIPPED_ITEM

  def normalize(raw)
    described_class.call(raw)
  end

  describe "a REFUND still pending seller action (real payload)" do
    let(:normalized) { normalize(pending_refund) }

    it "extracts external_id from order_id" do
      expect(normalized[:external_id]).to eq("585048935026951732")
    end

    it "extracts refund_amount from refund_amount.refund_total" do
      expect(normalized[:refund_amount]).to eq(157.19)
    end

    it "prefers return_reason_text (human-readable) over the raw return_reason code" do
      expect(normalized[:refund_reason]).to eq("Package arrived damaged. Example: spilled liquid, damaged box.")
    end

    it "maps RETURN_OR_REFUND_REQUEST_PENDING to pending" do
      expect(normalized[:status]).to eq("pending")
    end

    it "parses create_time (unix seconds) into ordered_at" do
      expect(normalized[:ordered_at]).to eq(Time.zone.at(1_785_166_760))
    end

    it "keeps return-level identifiers, the technical reason code and the raw payload in metadata" do
      expect(normalized[:metadata]).to eq(
        "return_id"     => "4041743519508366900",
        "return_type"   => "REFUND",
        "return_status" => "RETURN_OR_REFUND_REQUEST_PENDING",
        "return_reason" => "ecom_order_delivered_refund_and_return_reason_damaged",
        "update_time"   => 1_785_166_760,
        "source"        => "tiktok_return_refund_api",
        "raw"           => pending_refund
      )
    end
  end

  describe "a RETURN_AND_REFUND with the buyer already shipped the item back (real payload, physical-return fields)" do
    let(:normalized) { normalize(shipped_return_and_refund) }

    it "extracts external_id, amount and reason the same way regardless of the extra physical-return fields" do
      expect(normalized[:external_id]).to eq("585048935026951733")
      expect(normalized[:refund_amount]).to eq(89.90)
      expect(normalized[:refund_reason]).to eq("Received the wrong item.")
    end

    it "maps BUYER_SHIPPED_ITEM to pending" do
      expect(normalized[:status]).to eq("pending")
    end
  end

  # Nenhum return_status terminal (aprovado/rejeitado/completo/cancelado) foi
  # confirmado em produção ainda — só os dois acima. Enquanto isso, TODO
  # return_status desconhecido cai em "pending" por segurança, em vez de
  # arriscar classificar como processed/ignored com base numa suposição do
  # SDK de terceiros que nunca foi validada contra uma resposta real.
  describe "unconfirmed return_status values (no terminal state observed in production yet)" do
    it "defaults to pending for a status never seen in production" do
      normalized = normalize({ "order_id" => "1", "return_status" => "SOME_STATUS_NEVER_OBSERVED" })
      expect(normalized[:status]).to eq("pending")
    end

    it "defaults to pending even for the third-party SDK's guessed terminal-state strings" do
      %w[RETURN_OR_REFUND_REQUEST_SUCCESS RETURN_OR_REFUND_REQUEST_COMPLETE
         RETURN_OR_REFUND_REQUEST_REJECT RETURN_OR_REFUND_REQUEST_CANCEL].each do |unconfirmed_status|
        normalized = normalize({ "order_id" => "1", "return_status" => unconfirmed_status })
        expect(normalized[:status]).to eq("pending")
      end
    end

    it "defaults to pending when return_status is absent" do
      normalized = normalize({ "order_id" => "1" })
      expect(normalized[:status]).to eq("pending")
    end
  end

  it "falls back to the raw return_reason code when no human-readable text is present" do
    normalized = normalize({ "order_id" => "12345", "return_reason" => "SIZE_TOO_SMALL" })

    expect(normalized[:refund_reason]).to eq("SIZE_TOO_SMALL")
  end

  it "returns nil ordered_at when create_time is absent" do
    normalized = normalize({ "order_id" => "1" })

    expect(normalized[:ordered_at]).to be_nil
  end

  it "does not blow up on a blank/non-hash payload" do
    normalized = normalize(nil)

    expect(normalized[:external_id]).to be_nil
    expect(normalized[:refund_amount]).to eq(0.0)
    expect(normalized[:status]).to eq("pending")
  end
end
