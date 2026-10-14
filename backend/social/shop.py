"""Avatar ownership uses the shared wallet and owner-before-ledger lock order."""
from dataclasses import dataclass
from uuid import UUID

from django.contrib.auth import get_user_model
from django.db import transaction

from rewards.services import InsufficientPointsError, get_balance, spend_points

from .models import AvatarPurchase, AvatarPurchaseRequest, AvatarWardrobe


@dataclass(frozen=True)
class Product:
    code: str
    title: str
    description: str
    category: str
    price: int
    outfit_value: str


PRODUCTS = (
    Product("baseballCap", "Baseball cap", "A sporty cap for your walking avatar.", "hats", 60, "baseballCap"),
    Product("beanie", "Beanie", "A cosy knitted hat for cooler walks.", "hats", 50, "beanie"),
    Product("sunHat", "Sun hat", "A wide-brimmed hat for sunny adventures.", "hats", 70, "sunHat"),
    Product("stripedBandana", "Striped bandana", "Add stripes to your avatar's bandana.", "bandanas", 25, "striped"),
    Product("polkaDotBandana", "Polka-dot bandana", "Add playful dots to your avatar's bandana.", "bandanas", 20, "polkaDot"),
    Product("roundGlasses", "Round glasses", "A pair of round frames for your avatar.", "extras", 35, "roundGlasses"),
    Product("starBadge", "Star badge", "A bright star for your walking companion.", "extras", 15, "starBadge"),
)
CATALOGUE = {product.code: product for product in PRODUCTS}
CATEGORIES = {
    "hats": ("hat_product_code", "hat", "none"),
    "bandanas": ("bandana_product_code", "bandana_style", "classic"),
    "extras": ("extra_product_code", "decoration", "none"),
}


class AvatarShopError(Exception):
    def __init__(self, code, message, status=400):
        super().__init__(message)
        self.code = code
        self.status = status


def _lock_owner(user):
    owner = get_user_model().objects.select_for_update().filter(pk=user.pk).first()
    if owner is None or owner.role != "OWNER" or not owner.is_active or owner.deleted_at:
        raise AvatarShopError("OWNER_REQUIRED", "Only active dog owner accounts can access the avatar shop.", 403)
    return owner


def _product(product_code):
    product = CATALOGUE.get(product_code) if isinstance(product_code, str) else None
    if product is None:
        raise AvatarShopError("INVALID_PRODUCT", "This avatar product is unavailable.")
    return product


def _request_uuid(request_id):
    if not isinstance(request_id, (str, UUID)):
        raise AvatarShopError("INVALID_REQUEST", "request_id must be a UUID.")
    try:
        return UUID(str(request_id))
    except (ValueError, AttributeError):
        raise AvatarShopError("INVALID_REQUEST", "request_id must be a UUID.") from None


def _outfit(wardrobe, owned):
    result = {}
    for category, (field, key, fallback) in CATEGORIES.items():
        code = getattr(wardrobe, field, None)
        product = CATALOGUE.get(code)
        result[key] = product.outfit_value if product and product.category == category and code in owned else fallback
    return result


def avatar_outfit(user):
    """Public profile payload: enum selections only, with ownership checked."""
    if not user.pk or user.role != "OWNER" or not user.is_active or user.deleted_at:
        return _outfit(None, set())
    wardrobe = AvatarWardrobe.objects.filter(owner_id=user.pk).first()
    if wardrobe is None:
        return _outfit(None, set())
    owned = set(AvatarPurchase.objects.filter(owner_id=user.pk).values_list("product_code", flat=True))
    return _outfit(wardrobe, owned)


def _state(owner):
    owned = set(AvatarPurchase.objects.filter(owner=owner).values_list("product_code", flat=True))
    wardrobe = AvatarWardrobe.objects.filter(owner=owner).first()
    return {
        "balance": get_balance(owner),
        "products": [
            {"code": p.code, "title": p.title, "description": p.description, "category": p.category, "price": p.price}
            for p in PRODUCTS
        ],
        "owned": [product.code for product in PRODUCTS if product.code in owned],
        "outfit": _outfit(wardrobe, owned),
    }


@transaction.atomic
def shop_state(user):
    return _state(_lock_owner(user))


@transaction.atomic
def purchase_product(*, owner, product_code, request_id):
    product = _product(product_code)
    request_id = _request_uuid(request_id)
    owner = _lock_owner(owner)
    existing_request = AvatarPurchaseRequest.objects.select_related("purchase").filter(owner=owner, request_id=request_id).first()
    if existing_request:
        if existing_request.purchase.product_code != product.code:
            raise AvatarShopError("IDEMPOTENCY_CONFLICT", "This request ID was already used for another avatar product.", 409)
        return _state(owner)

    purchase = AvatarPurchase.objects.filter(owner=owner, product_code=product.code).first()
    if purchase is None:
        try:
            spend_entry = spend_points(user=owner, amount=product.price, source_reference=f"avatar-shop:{owner.pk}:{request_id}")
        except InsufficientPointsError:
            raise AvatarShopError("INSUFFICIENT_POINTS", "Not enough points to buy this avatar product.") from None
        purchase = AvatarPurchase.objects.create(
            owner=owner, product_code=product.code, request_id=request_id,
            point_cost_snapshot=product.price, spend_entry=spend_entry,
        )
    AvatarPurchaseRequest.objects.create(owner=owner, request_id=request_id, purchase=purchase)
    return _state(owner)


@transaction.atomic
def equip_product(*, owner, category, product_code):
    if category not in CATEGORIES:
        raise AvatarShopError("INVALID_CATEGORY", "Choose hats, bandanas or extras.")
    product = None if product_code is None else _product(product_code)
    if product and product.category != category:
        raise AvatarShopError("PRODUCT_CATEGORY_MISMATCH", "This product does not belong to the selected category.")
    owner = _lock_owner(owner)
    if product and not AvatarPurchase.objects.filter(owner=owner, product_code=product.code).exists():
        raise AvatarShopError("PRODUCT_NOT_OWNED", "Buy this product before wearing it.")
    wardrobe, _ = AvatarWardrobe.objects.get_or_create(owner=owner)
    field = CATEGORIES[category][0]
    setattr(wardrobe, field, product.code if product else None)
    wardrobe.save(update_fields=[field])
    return _state(owner)
