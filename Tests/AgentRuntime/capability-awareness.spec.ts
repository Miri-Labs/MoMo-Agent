/** Prompt/discovery contracts, using the shipped SuperAgent renderer and tool factories; no live model or profile. */
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { afterEach, expect, it, vi } from 'vitest'
import { composePrompt, Prompts, type PromptConfig } from '../../Vendor/SuperAgent/src/app/prompts.ts'
import { readResource, type ResourceHost } from '../../Vendor/SuperAgent/src/app/resources.ts'
import { mainTools, type MainToolsHost } from '../../Vendor/SuperAgent/src/app/tools/main.ts'
import { executorTools, type ExecutorToolsHost } from '../../Vendor/SuperAgent/src/app/tools/executor.ts'
import { momoComputerTools } from '../../Vendor/SuperAgent/src/app/tools/momo-computer.ts'
import type { Ticket } from '../../Vendor/SuperAgent/src/core/index.ts'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { Store } from '../../Vendor/SuperAgent/src/app/store.ts'

const root = resolve(import.meta.dirname, '../..')
const config: PromptConfig = JSON.parse(execFileSync('uv', ['run', '--no-project', 'python', '-B', '-c',
  'import json; from superagent_runtime import MOMO_PROMPT_CONFIG; print(json.dumps(MOMO_PROMPT_CONFIG))'], {
  cwd: root, env: { ...process.env, PYTHONPATH: resolve(root, 'Apps/MacApp/Runtime'), PYTHONDONTWRITEBYTECODE: '1' }, encoding: 'utf8',
}))

afterEach(() => { vi.unstubAllEnvs(); vi.restoreAllMocks() })

it('answers the first-turn computer use 配了什么 skill/plugin question from the main prompt, before loading a skill', () => {
  const prompt = composePrompt(config, 'orchestrator')
  const manifest = JSON.parse(readFileSync(resolve(root, 'Vendor/AgentDesktop/UPSTREAM.json'), 'utf8'))
  const backend = manifest.repository.split('/').at(-1)
  expect(prompt).toContain(backend)
  expect(prompt).toContain("orchestrator_read(resource='prompts')")
  expect(prompt).toContain('dsh-superagent-momo')
  expect(prompt).toContain('无需为读取自己的说明派发任务或联网搜索')
  expect(prompt).toContain('浏览器网页交互与原生桌面控制分别核实')
  expect(prompt).toContain('只在当前实际发现时才算已配置')
  expect(prompt).toContain('不是本机就绪证明')
  expect(prompt).toContain('未核实的权限与运行状态标为未知')
  expect(prompt).toContain('无需重复安装')
  expect(prompt).not.toContain('拥有完整执行能力')
})

it('keeps the first-turn overview in sync with actual worker tool names and backend descriptions without granting main execution', () => {
  vi.stubEnv('MOMO_DATA_DIR', '/fixture-only')
  vi.stubEnv('MOMO_COMPUTER_BRIDGE', 'http://127.0.0.1:12345')
  const host = { github: { deployment: { github: { login: 'fixture' } } } } as unknown as ExecutorToolsHost
  const worker = executorTools(host, { id: 'fixture' } as Ticket)
  const main = mainTools({} as MainToolsHost, { id: 'orchestrator-fixture' } as Agent)
  const prompt = composePrompt(config, 'orchestrator')
  const desktop = momoComputerTools(host, 'fixture')
  const documented = [...new Set([...prompt.matchAll(/`(computer_\w+)`/g)].map(match => match[1]))]
  expect(documented.sort()).toEqual(desktop.map(tool => tool.name).sort())
  for (const tool of desktop) {
    expect(worker.map(tool => tool.name)).toContain(tool.name)
    expect(main.map(tool => tool.name)).not.toContain(tool.name)
    expect(prompt).toContain(tool.name)
    expect(config.skills.momo).toContain(tool.name)
    expect(tool.description).toContain('agent-desktop')
  }
  expect(main.map(tool => tool.name)).toContain('orchestrator_read')
  expect(prompt).toContain('主会话没有这些执行工具并不表示 MoMo 未内置它们')
})

it.each(['MOMO_DATA_DIR', 'MOMO_COMPUTER_BRIDGE'])('distinguishes bundled code from an unregistered worker bridge when %s is absent', key => {
  vi.stubEnv('MOMO_DATA_DIR', '/fixture-only')
  vi.stubEnv('MOMO_COMPUTER_BRIDGE', 'http://127.0.0.1:12345')
  vi.stubEnv(key, '')
  expect(momoComputerTools({} as ExecutorToolsHost, 'fixture')).toEqual([])
  for (const role of ['orchestrator', 'worker'] as const) {
    const prompt = composePrompt(config, role)
    expect(prompt).toContain('工具缺失、被禁用或不可用时如实说明')
    expect(prompt).toContain('打包、当前角色的工具注册、系统权限和实际可运行是不同状态')
  }
})

function discoveryHost(currentConfig: PromptConfig, feishuConfigured = false): ResourceHost {
  // Use the real skill selection, with an in-memory prompt revision instead of a live profile/SQLite store.
  const prompts = new Prompts({} as Store, () => 100000, () => [], () => feishuConfigured)
  const version = { revision: 1, previousRevision: null, savedAt: '', source: 'fixture', config: currentConfig }
  return {
    masterId: 'orchestrator-fixture', settings: {},
    sessions: { status: () => ({ revision: 1, notificationPending: false, sessions: [] }) },
    prompts: {
      current: () => version, version: () => version, skills: (value: PromptConfig) => prompts.skills(value),
      history: () => ({ revisions: [], next_offset: null }), defaultChanged: () => [],
    },
    promptVersion: () => version,
  } as unknown as ResourceHost
}

it('discovers current skills after add/remove and omits unconfigured Feishu despite its bundled CLI/skill', async () => {
  for (const skills of [{ ...config.skills, browser: '# Current browser skill' }, { renamed: '# Replacement skill' }]) {
    const current = { ...config, skills }
    const host = discoveryHost(current)
    const result = await readResource(host, 'prompts', 0, 20) as { skills: { team: string[]; built_in: string[] }; read: string }
    expect(result.skills.team).toEqual(Object.keys(skills).map(name => `dsh-superagent-${name}`))
    expect(result.skills.built_in).not.toContain('dsh-superagent-feishu')
    // The advertised revision really is readable in full through the existing paged resource.
    let text = '', offset: number | null = 0
    do {
      const page = await readResource(host, result.read, offset, 8000) as { text: string; next_offset: number | null }
      text += page.text; offset = page.next_offset
    } while (offset !== null)
    expect(JSON.parse(text).config.skills).toEqual(skills)
  }
  const connected = await readResource(discoveryHost(config, true), 'prompts', 0, 20) as { skills: { built_in: string[] } }
  expect(connected.skills.built_in).toContain('dsh-superagent-feishu')
  expect(composePrompt(config, 'orchestrator')).toContain('不能证明 MoMo 已连接')
})
