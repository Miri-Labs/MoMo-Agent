"""Agent desktop tools use the same ownership boundary as the paired phone."""
import asyncio
import os
from pathlib import Path
import sys
import uuid
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
    lease=DesktopLease(data)
    with lease.locked():
        current=lease.read()
        if current['epoch']!=momo_control['epoch'] or current.get('agent_work')!={k:v for k,v in momo_control.items() if k!='epoch'}: raise RuntimeError('Desktop changed')
        current['observed_epoch']=current['epoch']; lease.write(current)
    return [ImageContent(type='image', data=result['jpeg'], mimeType='image/jpeg')]


@server.tool()
async def computer_input(kind: str, x: float = 0, y: float = 0, to_x: float = 0, to_y: float = 0,
                         text: str = '', key: str = '', delta: int = 0, momo_control: dict | None = None) -> dict:
    """Operate the Mac: click, double_click, right_click, drag, scroll, text or key. Coordinates normalized 0..1. Human takeover immediately blocks these tools; wait for the user to return control."""
    if not momo_control: raise RuntimeError('Missing native work authority')
    return await call('input', control=momo_control, event_id=str(uuid.uuid4()), event=dict(kind=kind, x=x, y=y, to_x=to_x, to_y=to_y, text=text, key=key, delta=delta))


if __name__ == '__main__': server.run()
