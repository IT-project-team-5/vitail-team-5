from django.urls import path

from .views import BreedListView, DogDetailView, DogGoalView, DogListCreateView


urlpatterns = [
    path("dogs", DogListCreateView.as_view(), name="dog-list-create"),
    path("dogs/breeds", BreedListView.as_view(), name="breed-list"),
    path("dogs/<int:pk>", DogDetailView.as_view(), name="dog-detail"),
    path("dogs/<int:pk>/goal", DogGoalView.as_view(), name="dog-goal"),
]
