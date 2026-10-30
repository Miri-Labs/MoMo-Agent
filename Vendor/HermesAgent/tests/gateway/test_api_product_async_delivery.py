"""A host-owned API conversation can receive process results; unrelated HTTP sessions cannot."""
from types import SimpleNamespace
from unittest.mock import Mock

from gateway.config import Platform
from gateway.session_api_completion import product_async_delivery


def test_owned_api_conversation_uses_its_served_adapter_and_preserves_non_push_transport():
    source = SimpleNamespace(platform=Platform.API_SERVER)
    context = SimpleNamespace(source=source, session_id='owned-session')
    product = SimpleNamespace(enabled=True, owns=lambda sid: sid == 'owned-session')
    adapter = SimpleNamespace(supports_async_delivery=False, _product_integration=product)
    runner = SimpleNamespace(_adapter_for_source=Mock(return_value=adapter))
    assert product_async_delivery(runner, context) is True
    runner._adapter_for_source.assert_called_once_with(source)
    assert adapter.supports_async_delivery is False
    context.session_id = 'unrelated-session'
    assert product_async_delivery(runner, context) is False
    product.enabled = False
    context.session_id = 'owned-session'
    assert product_async_delivery(runner, context) is False


def test_unserved_profile_or_generic_api_never_borrows_another_products_capability():
    context = SimpleNamespace(source=SimpleNamespace(platform=Platform.API_SERVER), session_id='owned-session')
    for adapter in (None, SimpleNamespace(supports_async_delivery=False)):
        runner = SimpleNamespace(_adapter_for_source=Mock(return_value=adapter))
        assert product_async_delivery(runner, context) is False
