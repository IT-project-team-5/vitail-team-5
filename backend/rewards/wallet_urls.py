from django.urls import path

from .views import WalletLedgerView, WalletView

urlpatterns = [
    path("", WalletView.as_view(), name="wallet-balance"),
    path("ledger", WalletLedgerView.as_view(), name="wallet-ledger"),
]
