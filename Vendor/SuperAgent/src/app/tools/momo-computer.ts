/** Built-in MoMo desktop tools. Native permissions and takeover stay in the Mac app. */
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { z } from 'zod'
import { liveTicket, runningAssignment } from '../../core/index.ts'
import type { ExecutorToolsHost } from './executor.ts'
import type { Tool } from './tool.ts'

export function momoComputerTools(host: ExecutorToolsHost, ticketId: string): Tool[] {
  const bridge = process.env.MOMO_COMPUTER_BRIDGE, data = process.env.MOMO_DATA_DIR
  if (!bridge || !data) return []
  const url = new URL(bridge)
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1') throw new Error('MoMo computer bridge must be loopback')
  const call = async (op: string, args: unknown, signal: AbortSignal) => {
    const secret = JSON.parse(await readFile(join(data, 'superagent/state/momo-bridge.json'), 'utf8')) as { secret: string }
    signal.throwIfAborted()
    const current = host.store.tickets.get(ticketId)
    const assignment = current && runningAssignment(current)
    if (!current || !liveTicket(current) || current.attention || !assignment) throw new Error('Ticket is not running')
    const response = await fetch(new URL('/momo/internal/superagent/computer', url), {
      method: 'POST', signal: AbortSignal.any([signal, AbortSignal.timeout(20000)]),
      headers: { 'content-type': 'application/json', 'x-momo-bridge': secret.secret },
      body: JSON.stringify({ ticket_id: ticketId, assignment_id: assignment.id, op, args }),
    })
    const result = await response.json() as { error?: string }
    if (!response.ok) throw new Error(result.error ?? `Computer bridge returned ${response.status}`)
    return result
  }
  return [
    {
      name: 'computer_snapshot',
      description: 'Read the Mac accessibility tree with bundled agent-desktop. Empty app uses the frontmost window. Use full @snapshot:eN refs with computer_action; complete=false means a partial tree. Re-read after actions or stale refs. User takeover blocks access.',
      schema: z.object({ app: z.string().max(512).default(''), depth: z.number().int().min(1).max(20).default(10) }).strict(),
      execute: (args, signal) => call('accessibility-snapshot', args, signal),
    },
    {
      name: 'computer_action',
      description: 'Act on a full ref from computer_snapshot using agent-desktop. set_value replaces text; type_text inserts. Headless semantic actions by default; headed=true explicitly allows physical input. Re-read stale/ambiguous refs. Never blindly repeat uncertain delivery; observe and verify the result.',
      schema: z.object({
        ref: z.string().regex(/^@[A-Za-z0-9_-]+:e[0-9]+$/),
        action: z.enum(['click', 'double_click', 'right_click', 'set_value', 'focus', 'expand', 'collapse', 'select', 'toggle', 'check', 'uncheck', 'scroll', 'scroll_to', 'press_key', 'type_text', 'clear', 'hover']),
        text: z.string().max(8000).default(''), key: z.string().max(80).default(''),
        modifiers: z.array(z.enum(['meta', 'ctrl', 'alt', 'shift'])).max(4).default([]),
        direction: z.enum(['up', 'down', 'left', 'right']).default('down'), amount: z.number().int().min(1).max(100).default(3),
        headed: z.boolean().default(false),
      }).strict(),
      execute: (args, signal) => call('accessibility-action', args, signal),
    },
  ]
}
