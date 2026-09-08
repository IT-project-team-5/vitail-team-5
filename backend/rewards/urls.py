from django.urls import path

from .views import RedemptionCollectView, RedemptionListCreateView, RewardListView

urlpatterns = [
    path("", RedemptionListCreateView.as_view(), name="redemption-list-create"),
    path("rewards", RewardListView.as_view(), name="reward-list"),
    path("<int:redemption_id>/collect", RedemptionCollectView.as_view(), name="redemption-collect"),
]
