# Point-in-time audit trail of one Product's stock figures as read from
# an ERP sync (idworks today — see Integrations::Idworks::StockSyncService).
# Never edited by a user; one row per product per sync run, so
# Product's own cached qty_* columns can be trusted as "current" while
# this table answers "what did stock look like on date X".
class StockSnapshot < ApplicationRecord
  belongs_to :tenant
  belongs_to :product
end
