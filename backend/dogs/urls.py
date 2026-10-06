from django.urls import path

from .views import BreedListView, DogDetailView, DogListCreateView, DogPhotoView, DogGoalView


urlpatterns = [
    path("dogs/<int:pk>/goal", DogGoalView.as_view(), name="dog-goal"),
    path("dogs", DogListCreateView.as_view(), name="dog-list-create"),
    path("dogs/breeds", BreedListView.as_view(), name="breed-list"),
    path("dogs/<int:pk>", DogDetailView.as_view(), name="dog-detail"),
    path("dogs/<int:pk>/photo", DogPhotoView.as_view(), name="dog-photo"),
]
