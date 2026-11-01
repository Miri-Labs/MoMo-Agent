import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { Ticket } from '../src/core/index.ts'
import type { ExecutorToolsHost } from '../src/app/tools/executor.ts'
import { momoComputerTools } from '../src/app/tools/momo-computer.ts'

let directory: string
let ticket: Ticket
const get = vi.fn(() => ticket)
const host = { store: { tickets: { get } } } as unknown as ExecutorToolsHost
beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'momo-computer-test-'))
  await mkdir(join(directory, 'superagent/state'), { recursive: true })
  await writeFile(join(directory, 'superagent/state/momo-bridge.json'), JSON.stringify({ secret: 'fixture-only' }))
  vi.stubEnv('MOMO_DATA_DIR', directory)
  vi.stubEnv('MOMO_COMPUTER_BRIDGE', 'http://127.0.0.1:12345')
  ticket = { id: 'ticket-1', assignments: [{ id: 'run-1', state: 'running' }] } as Ticket
})
afterEach(async () => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.clearAllMocks(); await rm(directory, { recursive: true, force: true }) })

it('registers only in a MoMo host and requires a loopback bridge', () => {
  expect(momoComputerTools(host, ticket.id).map(t => t.name)).toEqual(['computer_snapshot', 'computer_action'])
  vi.stubEnv('MOMO_COMPUTER_BRIDGE', '')
  expect(momoComputerTools(host, ticket.id)).toEqual([])
  vi.stubEnv('MOMO_COMPUTER_BRIDGE', 'https://outside.example')
  expect(() => momoComputerTools(host, ticket.id)).toThrow('loopback')
})

it('injects ticket authority outside the schema and preserves upstream envelopes', async () => {
  const result = { ok: true, data: { complete: false, snapshot_id: 's1' } }
  const fetch = vi.fn().mockResolvedValue({ ok: true, json: async () => result })
  vi.stubGlobal('fetch', fetch)
  const tool = momoComputerTools(host, ticket.id)[0]!
  expect(tool.schema.safeParse({ ticket_id: 'other' }).success).toBe(false)
  expect(await tool.execute(tool.schema.parse({}), new AbortController().signal)).toEqual(result)
  const [url, init] = fetch.mock.calls[0]!
  expect(String(url)).toBe('http://127.0.0.1:12345/momo/internal/superagent/computer')
  expect(init.headers['x-momo-bridge']).toBe('fixture-only')
  expect(JSON.parse(init.body)).toEqual({ ticket_id: 'ticket-1', assignment_id: 'run-1', op: 'accessibility-snapshot', args: { app: '', depth: 10 } })
})

it('checks current assignment and aborts before sending a stopped or cancelled tool', async () => {
  const fetch = vi.fn(); vi.stubGlobal('fetch', fetch)
  const tool = momoComputerTools(host, ticket.id)[0]!
  ticket = { ...ticket, assignments: [] }
  await expect(tool.execute({}, new AbortController().signal)).rejects.toThrow('not running')
  const controller = new AbortController(); controller.abort()
  await expect(tool.execute({}, controller.signal)).rejects.toThrow()
  expect(fetch).not.toHaveBeenCalled()
})

it('rejects bare refs and returns action errors without automatic retries', async () => {
  const tool = momoComputerTools(host, ticket.id)[1]!
  expect(tool.schema.safeParse({ ref: '@e1', action: 'click' }).success).toBe(false)
  const result = { ok: false, error: { code: 'STALE_REF', delivery: 'not_started' } }
  const fetch = vi.fn().mockResolvedValue({ ok: true, json: async () => result }); vi.stubGlobal('fetch', fetch)
  expect(await tool.execute(tool.schema.parse({ ref: '@s1:e1', action: 'click' }), new AbortController().signal)).toEqual(result)
  expect(fetch).toHaveBeenCalledTimes(1)
})
