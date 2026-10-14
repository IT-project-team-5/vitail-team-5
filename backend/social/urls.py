from django.urls import path

from . import shop_views, views

urlpatterns = [
    path("avatar-shop", shop_views.AvatarShopView.as_view()),
    path("avatar-shop/purchases", shop_views.AvatarPurchaseView.as_view()),
    path("avatar-shop/outfit", shop_views.AvatarOutfitView.as_view()),
    path("overview", views.OverviewView.as_view()),
    path("users", views.UserSearchView.as_view()),
    path("friend-requests", views.FriendRequestView.as_view()),
    path("friend-requests/<int:relationship_id>/respond", views.FriendResponseView.as_view()),
    path("friends/<str:public_id>/remove", views.FriendRemoveView.as_view()),
    path("blocks", views.BlockView.as_view()),
    path("blocks/<str:public_id>/remove", views.UnblockView.as_view()),
    path("preferences", views.PreferencesView.as_view()),
    path("map", views.MapView.as_view()),
    path("walk-sessions", views.SessionCreateView.as_view()),
    path("walk-sessions/current", views.CurrentSessionView.as_view()),
    path("walk-sessions/<int:session_id>/location", views.PresenceView.as_view()),
    path("walk-sessions/<int:session_id>/state", views.SessionStateView.as_view()),
    path("net-walk-invitations", views.InvitationView.as_view()),
    path("net-walk-invitations/<int:invitation_id>/respond", views.InvitationResponseView.as_view()),
    path("net-walk-invitations/<int:invitation_id>/end", views.InvitationEndView.as_view()),
]
