"""Agent desktop tools use the same ownership boundary as the paired phone."""
import asyncio
import os
from pathlib import Path
import sys
import uuid
from typing import Literal
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Access'))
from desktop_control import native_request, DesktopLease
from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ImageContent

server = MCPServer('MoMo Agent computer')
data = Path(os.environ['MOMO_AGENT_DIRECTORY'])


async def call(op, **kwargs):
    result = await native_request(data, dict(op=op, actor='agent', **kwargs))
    if 'error' in result: raise ToolError(result['error'])
    return result


@server.tool()
async def computer_screenshot(momo_control: dict | None = None) -> list[ImageContent]:
    """View the Mac desktop. Refused while the user holds control; never bypass that boundary."""
    if not momo_control: raise RuntimeError('Missing native work authority')
    result = await call('frame', control=momo_control)
    mark_observed(momo_control)
    return [ImageContent(type='image', data=result['jpeg'], mimeType='image/jpeg')]


def mark_observed(momo_control):
    lease=DesktopLease(data)
    with lease.locked():
        current=lease.read()
        if current['epoch']!=momo_control['epoch'] or current.get('agent_work')!={k:v for k,v in momo_control.items() if k!='epoch'}: raise RuntimeError('Desktop changed')
        current['observed_epoch']=current['epoch']; lease.write(current)


@server.tool()
async def computer_input(kind: str, x: float = 0, y: float = 0, to_x: float = 0, to_y: float = 0,
                         text: str = '', key: str = '', delta: int = 0, momo_control: dict | None = None) -> dict:
    """Operate the Mac: click, double_click, right_click, drag, scroll, text or key. Coordinates normalized 0..1. Human takeover immediately blocks these tools; wait for the user to return control."""
    if not momo_control: raise RuntimeError('Missing native work authority')
    return await call('input', control=momo_control, event_id=str(uuid.uuid4()), event=dict(kind=kind, x=x, y=y, to_x=to_x, to_y=to_y, text=text, key=key, delta=delta))


@server.tool()
async def computer_snapshot(app: str = '', depth: int = 10, momo_control: dict | None = None) -> dict:
    """Read the Mac accessibility tree using bundled agent-desktop. Empty app means frontmost window. Use full @snapshot:eN refs with computer_action. complete=false means a partial tree, never absence of an unseen control. Re-read after actions, stale refs or user takeover. Screenshot/input remain available for inaccessible custom surfaces."""
    if not momo_control: raise RuntimeError('Missing native work authority')
    result = (await call('accessibility-snapshot', control=momo_control, app=app, depth=depth))['result']
    if result.get('ok'): mark_observed(momo_control)
    return result


@server.tool()
async def computer_action(ref: str, action: Literal['click', 'double_click', 'right_click', 'set_value', 'focus', 'expand', 'collapse', 'select', 'toggle', 'check', 'uncheck', 'scroll', 'scroll_to', 'press_key', 'type_text', 'clear', 'hover'],
                          text: str = '', key: str = '', modifiers: list[Literal['meta', 'ctrl', 'alt', 'shift']] | None = None,
                          direction: Literal['up', 'down', 'left', 'right'] = 'down', amount: int = 3, headed: bool = False,
                          momo_control: dict | None = None) -> dict:
    """Act on a full ref from computer_snapshot, via agent-desktop. set_value replaces text; type_text inserts. Semantic/headless by default; headed=true explicitly allows foreground physical input. Stale/ambiguous refs require a new snapshot. Never blindly retry an action with uncertain delivery; observe the result before deciding. Human takeover blocks all actions."""
    if not momo_control: raise RuntimeError('Missing native work authority')
    return (await call('accessibility-action', control=momo_control, event=dict(ref=ref, action=action, text=text, key=key,
        modifiers=modifiers or [], direction=direction, amount=amount, headed=headed)))['result']


if __name__ == '__main__': server.run()
