require "rails_helper"

# Regression: this class used to fetch nf_gross_value/nf_discount/
# nf_freight/tax_amount/real_freight_cost from idworks' invoice endpoints.
# Confirmed via swagger.idworks.com.br (2026-07-10) that those endpoints
# carry no financial data at all — see the class comment. It's now an
# intentional, documented stub that's never called
# (Integrations::Idworks::OrderSyncService replaced it for
# real_freight_cost). This spec just locks in that it fails loudly instead
# of silently doing nothing if something calls it by mistake.
RSpec.describe Integrations::InvoiceSyncService do
  it "raises NotImplementedError explaining why, instead of silently no-op'ing" do
    expect { described_class.call(double) }.to raise_error(NotImplementedError, /idworks' invoice endpoints have no financial data/)
  end
end
