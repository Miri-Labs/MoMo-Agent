"""Host-installed API completion producer; never selectable by HTTP input.

The embedding application owns receipts. Hermes retains the sole FIFO, execution
fence, approval gates and unknown-outcome recovery. Generic Hermes is unchanged.
"""
from functools import partial

from gateway.session_api import restore_api_session
from gateway.session_contract import SessionRef
from hermes_state_runtime import RuntimeStoreError, admit_session_input

_factory = None


def install_product_integration(factory):
    global _factory
    _factory = factory


def wire_product_integration(adapter, app):
    if _factory is not None:
        adapter._product_integration = _factory(adapter, app)


def product_async_delivery(runner, context):
    """A served product owner can receive receipts without making the HTTP adapter push-capable."""
    from gateway.config import Platform
    if context.source.platform != Platform.API_SERVER: return False
    adapter = runner._adapter_for_source(context.source)
    product = getattr(adapter, '_product_integration', None)
    return getattr(product, 'enabled', False) is True and product.owns(context.session_id) is True


def check_api_completion(authority, ref, row):
    live = authority.sessions[ref.session_id]
    adapter = authority.runner._adapter_for_source(live.source)
    product = getattr(adapter, '_product_integration', None)
    if (getattr(product, 'enabled', False) is not True or row['principal_id'] != 'momo-completion'
            or set(row['payload']) != {'text', 'api_automation_v1'}):
        raise RuntimeStoreError('permission_denied')
    product.validate_completion(authority, ref, row)


async def admit_api_completion(adapter, receipt):
    from gateway.session_authorities import require_active_authority
    from gateway.session_runtime_workers import tracked_write
    authority = require_active_authority(adapter.gateway_runner)
    sid = authority.logical_owner(receipt['owner'])
    ref = restore_api_session(authority, sid)
    payload = {'text': receipt['prompt'], 'api_automation_v1': {
        'event_key': receipt['event_key'], 'owner': sid,
        'source_message_id': receipt['source_message_id']}}
    attempt = receipt.get('report_attempt', 0)
    request_id = 'momo_completion_' + receipt['event_key'] + ('_report_' + str(attempt) if attempt else '')
    check_api_completion(authority, ref, {'principal_id': 'momo-completion',
        'request_id': request_id, 'target_session_id': sid, 'payload': payload})
    row = await tracked_write(authority, partial(admit_session_input, authority.db,
        epoch=authority.epoch, principal_id='momo-completion', session_id=sid,
        request_id=request_id, payload=payload, _authorize_write=authority._admission_gate()),
        ordered=True, after=lambda _: authority._schedule(ref))
    return row
