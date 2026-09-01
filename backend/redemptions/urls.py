from django.urls import path

from .views import RedemptionOrderCollectView, RedemptionOrderListCreateView

urlpatterns = [
    path("orders", RedemptionOrderListCreateView.as_view(), name="redemption-orders"),
    path(
        "orders/<int:order_id>/collect",
        RedemptionOrderCollectView.as_view(),
        name="redemption-order-collect",
    ),
]
