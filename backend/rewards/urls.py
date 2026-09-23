from django.urls import re_path

from .views import (
    CafeOrderFeedView, CafeProductListCreateView, CafeProductUpdateView,
    RedemptionCollectView, RedemptionListCreateView,
    RewardListView, WalletLedgerView, WalletView,
)


urlpatterns = [
    re_path(r"^wallet/?$", WalletView.as_view(), name="wallet"),
    re_path(r"^wallet/ledger/?$", WalletLedgerView.as_view(), name="wallet-ledger"),
    re_path(r"^redemptions/?$", RedemptionListCreateView.as_view(), name="redemption-list-create"),
    re_path(r"^redemptions/rewards/?$", RewardListView.as_view(), name="reward-list"),
    re_path(r"^redemptions/(?P<redemption_id>\d+)/collect/?$", RedemptionCollectView.as_view(), name="redemption-collect"),
    re_path(r"^cafe/orders/?$", CafeOrderFeedView.as_view(), name="cafe-orders"),
    re_path(r"^cafe/products/?$", CafeProductListCreateView.as_view(), name="cafe-product-list-create"),
    re_path(r"^cafe/products/(?P<product_id>\d+)/?$", CafeProductUpdateView.as_view(), name="cafe-product-update"),
]
