import { o as fill, p as liveTicket } from "./kv-BKzBGVb4.js";
import { accessSync, constants, realpathSync, statSync } from "node:fs";
import { basename, delimiter, isAbsolute, join, resolve } from "node:path";
import { createHash } from "node:crypto";
import { z } from "zod";
import { lstat, mkdir, readFile, readdir, rename, unlink, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import s from "@deepseek-ai/schemastery";
//#region src/core/ids.ts
/** Stable content-derived identifiers; equal inputs always produce the same id. */
function key(...values) {
	return createHash("sha256").update(JSON.stringify(values)).digest("hex").slice(0, 32);
}
//#endregion
//#region src/limits.ts
/** Validation bounds shared between host schemas and management panel forms. */
const LIMITS = {
	ruleName: 100,
	ruleInstruction: 2e3,
	evalTimeoutSeconds: {
		min: 30,
		max: 600
	},
	maxWorkers: {
		min: 1,
		max: 16
	},
	prepareCommand: 4e3,
	promptMaxChars: {
		min: 1e3,
		max: 1e6
	},
	admissionContextMaxPages: {
		min: 1,
		max: 100
	},
	admissionContextTimeoutMs: {
		min: 1,
		max: 9e4
	}
};
//#endregion
//#region src/setup.ts
/** Structured startup and configuration errors with the settings location where the operator can fix them. */
const SETUP_PROBLEMS = {
	foreignFile: ["deployment", "{file} was not written by dsh-superagent; move it, or choose another state directory."],
	gitTooOld: ["deployment", "git does not read the github.com credential configuration dsh-superagent writes; dsh-superagent needs git 2.32 or later."],
	environmentFailed: ["deployment", "Preparing the agent environment failed."],
	repositoryUnset: ["github", "The GitHub Source names no repository."],
	agentCliUnset: ["github", "The agent GitHub CLI is not set."],
	agentCliMissing: ["github", "The agent GitHub CLI was not found."],
	agentCliSignedOut: ["github", "The agent GitHub CLI cannot read its account."],
	agentCliNoAccount: ["github", "The agent GitHub CLI did not report a GitHub account."],
	repositoryUnreadable: ["github", "@{account} cannot read {repository}."],
	repositoryUnreported: ["github", "The agent GitHub CLI did not return {repository}."],
	repositoryReadOnly: ["github", "@{account} cannot push to {repository}."],
	feishuCliFailed: ["feishu", "The bot lark-cli does not work."],
	feishuNoApp: ["feishu", "auth status of the bot lark-cli did not report the app."],
	feishuBotNotReady: ["feishu", "The bot identity of app {app} is {status}; configure the app secret with lark-cli."],
	feishuUserIdentity: ["feishu", "The bot lark-cli allows user identities (strict mode {mode}); give the bot its own lark-cli configuration in strict mode bot, as docs/006-deployment.md describes."],
	feishuNoBot: ["feishu", "The Feishu bot API did not return the bot's open_id."]
};
/**
* Thrown by deployment and account verification checks when a required CLI, account, or repository check fails.
* `Setup` records it for the management overview, and the HTTP layer returns `problem` so the panel can localize it.
*/
var SetupError = class extends Error {
	code;
	values;
	place;
	constructor(code, values = {}) {
		const [place, text] = SETUP_PROBLEMS[code];
		const sentence = fill(text, values);
		super(values.output ? `${sentence}\n${values.output}` : sentence);
		this.code = code;
		this.values = values;
		this.place = place;
	}
	get problem() {
		return {
			place: this.place,
			code: this.code,
			values: this.values,
			detail: this.message
		};
	}
};
//#endregion
//#region src/infra/commands.ts
/** Subprocess wrapper for running gh, lark-cli, and git commands under the deployment's configured accounts. */
const exec = promisify(execFile);
const TIMEOUT_MS = 9e4;
/**
* Error thrown by Commands when a CLI invocation fails, capturing stderr diagnostics, API error codes, and exit status without echoing command arguments.
* Source channels and pollers inspect its code to distinguish deleted conversations from retryable failures.
*/
var CliError = class extends Error {
	code;
	exitCode;
	constructor(message, code, exitCode) {
		super(message);
		this.code = code;
		this.exitCode = exitCode;
	}
};
/** Extracts a sanitized error from a failed subprocess without echoing argv, which may contain message text. */
function commandError(error, program = "command") {
	if (error instanceof Error && error.name === "AbortError") return error;
	const exitCode = error && typeof error === "object" && "code" in error && typeof error.code === "number" ? error.code : void 0;
	if (error && typeof error === "object" && "stderr" in error && typeof error.stderr === "string") {
		const stderr = error.stderr.trim();
		let parsed;
		try {
			parsed = JSON.parse(stderr.slice(stderr.indexOf("{")));
		} catch {}
		const code = parsed?.error?.code;
		if (parsed?.error?.message) return new CliError(`${parsed.error.message}${code ? ` (${code})` : ""}`, code, exitCode);
		if (stderr) return new CliError(stderr.slice(0, 2e3), Number(/\bHTTP (\d{3})\b/.exec(stderr)?.[1]) || void 0, exitCode);
	}
	return new CliError(`${basename(program)} ${ended(error)}`, void 0, exitCode);
}
function ended(error) {
	const { killed, signal, code } = error ?? {};
	if (code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") return "printed more output than it may";
	if (killed && signal === "SIGTERM") return `timed out after ${TIMEOUT_MS / 1e3} s`;
	if (signal) return `was stopped by ${signal}`;
	if (typeof code === "number") return `exited with code ${code}`;
	return typeof code === "string" ? `could not run: ${code}` : "failed";
}
/** Parses array elements against a schema, skipping invalid items and incrementing `tally.skipped`. */
function validItems(item, list, tally) {
	const items = list.flatMap((value) => {
		const parsed = item.safeParse(value);
		return parsed.success ? [parsed.data] : [];
	});
	if (tally) tally.skipped += list.length - items.length;
	return items;
}
/** Rewrites Feishu error 232011 (bot not in chat) with remediation instructions. */
function membership(error) {
	if (!(error instanceof CliError) || error.code !== 232011) return error;
	return new CliError("The Feishu bot is not a member of the chat. Add the bot in the chat settings, then retry.", error.code, error.exitCode);
}
/**
* Executes gh, lark-cli, and git subprocesses with deployment account credentials, timeouts, and abort signals.
* Restricts GitHub API calls to the configured repository and translates CLI failures into CliError instances for Sources, MasterAssessor, Outbox, and Settings.
*/
var Commands = class Commands {
	resolved;
	environment;
	signal;
	/**
	* @param resolved - returns the resolved deployment setup, or throws while setup is still pending.
	* @param environment - variables overriding `process.env` for every command (such as isolated git settings).
	*/
	constructor(resolved, environment, signal) {
		this.resolved = resolved;
		this.environment = environment;
		this.signal = signal;
	}
	get deployment() {
		return this.resolved();
	}
	get repository() {
		return this.deployment.repository;
	}
	withSignal(signal) {
		return signal ? new Commands(this.resolved, this.environment, AbortSignal.any([this.signal, signal])) : this;
	}
	async run(program, args, cwd) {
		try {
			const { stdout } = await exec(program, args, {
				cwd,
				signal: this.signal,
				timeout: TIMEOUT_MS,
				maxBuffer: 16777216,
				env: {
					...process.env,
					...this.environment,
					GH_PROMPT_DISABLED: "1",
					LARKSUITE_CLI_NO_UPDATE_NOTIFIER: "1",
					LARKSUITE_CLI_NO_SKILLS_NOTIFIER: "1"
				}
			});
			return stdout;
		} catch (error) {
			throw commandError(error, program);
		}
	}
	/** Runs the agent's GitHub CLI and parses its JSON output; callers should prefer `api`, which is restricted to the configured repository and validates output. */
	async gh(args) {
		return JSON.parse(await this.run(this.deployment.github.cli, args));
	}
	async api(schema, ...rest) {
		if (typeof schema === "string") return this.run(this.deployment.github.cli, [
			"api",
			this.path(schema),
			...rest
		]);
		const [path = "", ...flags] = rest;
		return schema.parse(await this.gh([
			"api",
			this.path(path),
			...flags
		]));
	}
	/** Fetches all pages of a GitHub API list within the configured repository, skipping items that fail schema validation. */
	async pages(item, path, tally) {
		return validItems(item, z.array(z.array(z.unknown())).parse(await this.gh([
			"api",
			this.path(path),
			"--paginate",
			"--slurp"
		])).flat(), tally);
	}
	path(path) {
		if (/^\/|^[a-z]+:|(^|\/)\.\.?(\/|\?|$)/i.test(path)) throw new Error("GitHub calls are restricted to the configured repository");
		return path ? `repos/${this.repository}/${path}` : `repos/${this.repository}`;
	}
	/**
	* Runs the Feishu bot's `lark-cli` and returns the JSON `data` payload.
	* @throws CliError with Feishu's error code on failure (rewriting 232011 when the bot is not in the chat).
	*/
	async lark(args, cwd) {
		const bot = this.deployment.feishu;
		if (!bot) throw new Error("The Feishu Source has no working bot CLI");
		const output = await this.run(bot.cli, [
			...args,
			"--as",
			"bot",
			"--format",
			"json"
		], cwd).catch((error) => {
			throw membership(error);
		});
		const result = JSON.parse(output);
		const code = result.error?.code;
		if (!result.ok) throw membership(new CliError(`${result.error?.message ?? "Feishu command failed"}${code ? ` (${code})` : ""}`, code));
		return result.data;
	}
	/** Runs `git` on PATH using the agent's isolated git environment and credential helper. */
	async git(args, cwd) {
		return this.run("git", args, cwd);
	}
};
//#endregion
//#region src/infra/environment.ts
/**
* Process environment and CLI shims that bind git, gh, and lark-cli to the deployment's accounts and block disallowed commands.
* Variables read by workers avoid `KEY|PASSWORD|SECRET|TOKEN` in their names because DSH strips credential-shaped variables from child environments.
* Provides default-path guardrails rather than an OS-level security boundary, as workers run under the operator's OS user.
*/
const MARKER = "# Written by dsh-superagent on every start; edits are lost.";
/** Markers of files written under the project's earlier names (`dsh-tag`, `dsh-go`, `dsh-freelancer`), which `dsh-superagent` owns and replaces too. */
const LEGACY_MARKERS = [
	"dsh-tag",
	"dsh-go",
	"dsh-freelancer"
].map((name) => `# Written by ${name} on every start; edits are lost.`);
/** Commands workers need, which `blockedCommands` cannot block: the shims and git. */
const WORKER_COMMANDS = [
	"gh",
	"git",
	"lark-cli"
];
const workerBin = (stateDir) => join(stateDir, "worker-bin");
const workerGitConfig = (stateDir) => join(stateDir, "worker-gitconfig");
const shellQuote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
const gitQuote = (value) => `"${value.replace(/[\\"]/g, (char) => `\\${char}`)}"`;
const credentialHelper = (cli) => `!${shellQuote(cli)} auth git-credential`;
function sameDirectory(a, b) {
	const real = (path) => {
		try {
			return realpathSync(path);
		} catch {
			return resolve(path);
		}
	};
	return real(a) === real(b);
}
function withoutDirectory(path, dir) {
	return path.split(delimiter).filter((entry) => !sameDirectory(entry, dir)).join(delimiter);
}
/**
* The variables that tell git which repository, work tree and index to act on. A host started inside git, such as by
* `git rebase --exec`, passes them on, and a git started below it would act on that repository. GIT_CEILING_DIRECTORIES is
* kept: it names no repository, and it stops git's search for one where the operator chose.
*/
const GIT_LOCATION = [
	"GIT_DIR",
	"GIT_WORK_TREE",
	"GIT_INDEX_FILE",
	"GIT_PREFIX",
	"GIT_COMMON_DIR",
	"GIT_OBJECT_DIRECTORY",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES",
	"GIT_NAMESPACE"
];
/**
* Returns environment variable overrides that strip ambient GitHub tokens, interactive prompts, the repository the host's own
* environment may name, and operator git identity/config overrides.
*/
function agentVariables(stateDir) {
	return {
		GH_TOKEN: void 0,
		GITHUB_TOKEN: void 0,
		...Object.fromEntries(GIT_LOCATION.map((name) => [name, void 0])),
		GIT_CONFIG_GLOBAL: workerGitConfig(stateDir),
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_CONFIG_COUNT: void 0,
		GIT_CONFIG_PARAMETERS: void 0,
		GIT_ASKPASS: "",
		SSH_ASKPASS: void 0,
		GIT_TERMINAL_PROMPT: "0",
		GIT_AUTHOR_NAME: void 0,
		GIT_COMMITTER_NAME: void 0,
		GIT_AUTHOR_EMAIL: void 0,
		GIT_COMMITTER_EMAIL: void 0
	};
}
/** True when a regular file starts with the dsh-superagent marker in its first two lines; a symbolic link, directory, or other non-regular file never counts as written by dsh-superagent. */
async function written(file) {
	if (!(await lstat(file)).isFile()) return false;
	const head = (await readFile(file, "utf8")).split("\n", 2);
	return [MARKER, ...LEGACY_MARKERS].some((marker) => head.includes(marker));
}
async function own(file, text, mode = 420) {
	let foreign = false;
	try {
		foreign = !await written(file);
	} catch {}
	if (foreign) throw new SetupError("foreignFile", { file });
	const temporary = `${file}.${process.pid}.tmp`;
	await writeFile(temporary, text, { mode });
	await rename(temporary, file);
}
/**
* Atomically writes worker CLI shims and the isolated git configuration file into the state directory, refusing to overwrite foreign files.
* Each shim strips the shim directory from PATH before exec so wrapper scripts resolving `gh` or `lark-cli` by name reach the real binary.
*/
async function writeEnvironment(deployment, blockedCommands) {
	const { stateDir, repository, github, feishu } = deployment;
	const dir = workerBin(stateDir);
	await mkdir(dir, { recursive: true });
	const before = await readdir(dir);
	for (const name of before) {
		const file = join(dir, name);
		if (!await written(file)) throw new SetupError("foreignFile", { file });
	}
	const kept = /* @__PURE__ */ new Set();
	const shim = async (name, body) => {
		const temporary = join(dir, `.${name}.${process.pid}.tmp`);
		await writeFile(temporary, `#!/bin/sh\n${MARKER}\n${body}\n`, { mode: 493 });
		await rename(temporary, join(dir, name));
		kept.add(name);
	};
	const withoutShims = [
		`self=${shellQuote(dir)}`,
		"rest=",
		"IFS=:",
		"set -f",
		"for entry in $PATH; do [ \"$entry\" = \"$self\" ] || rest=\"${rest:+$rest:}$entry\"; done",
		"set +f",
		"unset IFS",
		"PATH=$rest",
		"export PATH"
	].join("\n");
	const run = (program) => `${withoutShims}\nexec ${shellQuote(program)} "$@"`;
	const fail = (message) => `echo ${shellQuote(message)} >&2\nexit 1`;
	await shim("gh", github.cli ? run(github.cli) : fail("gh is unavailable: this installation has no GitHub repository."));
	await shim("lark-cli", feishu ? run(feishu.cli) : fail("lark-cli is unavailable: this installation has no Feishu bot."));
	for (const name of new Set(blockedCommands.filter((name) => !WORKER_COMMANDS.includes(name)))) await shim(name, fail(github.cli ? `${name} is blocked in this installation; use gh, which acts as ${github.login}.` : `${name} is blocked in this installation.`));
	for (const name of before) if (!kept.has(name)) await unlink(join(dir, name));
	await own(workerGitConfig(stateDir), [
		MARKER,
		"[user]",
		"	useConfigOnly = true",
		"[credential]",
		"	helper =",
		...github.cli ? ["[credential \"https://github.com\"]", `\thelper = ${gitQuote(credentialHelper(github.cli))}`] : [],
		"[url \"https://github.com/\"]",
		"	insteadOf = git@github.com:",
		"	insteadOf = ssh://git@github.com/",
		"[filter \"lfs\"]",
		"	clean = git-lfs clean -- %f",
		"	smudge = git-lfs smudge -- %f",
		"	process = git-lfs filter-process",
		"	required = true"
	].join("\n") + "\n");
}
/** Applies environment overrides and prepends worker shims to `process.env.PATH`, returning a restore callback. */
function applyEnvironment(variables, stateDir, path) {
	const values = {
		...variables,
		PATH: [workerBin(stateDir), path].join(delimiter)
	};
	const previous = Object.fromEntries(Object.keys(values).map((name) => [name, process.env[name]]));
	const apply = (env) => {
		for (const [name, value] of Object.entries(env)) if (value === void 0) delete process.env[name];
		else process.env[name] = value;
	};
	apply(values);
	return () => {
		apply(previous);
	};
}
/** Spawns a command through the DSH subprocess runtime, which strips credential-shaped environment variables. */
async function runAsWorker(subprocess, argv, cwd, signal, env) {
	const handle = subprocess.spawn({
		argv,
		cwd,
		graceMs: 2e3,
		signal,
		...env ? { env } : {},
		stdio: {
			stdin: "ignore",
			stdout: { maxBytes: 1 << 20 },
			stderr: { maxBytes: 65536 }
		}
	});
	const { exitCode } = await handle.done;
	const read = (reader) => reader?.readFrom(0).text ?? "";
	if (exitCode === 0) return read(handle.collected.stdout);
	const ended = exitCode === null ? "was stopped before it finished" : `exited with ${exitCode}`;
	throw new CliError(read(handle.collected.stderr).trim() || `${argv.join(" ")} ${ended}`, void 0, exitCode ?? void 0);
}
/** Verifies that worker git invocations resolve the deployment's GitHub credential helper. */
async function verifyEnvironment(deployment, subprocess, signal) {
	const { github, stateDir } = deployment;
	if (!github.cli) return;
	if ((await runAsWorker(subprocess, [
		"git",
		"config",
		"-z",
		"--show-origin",
		"--get-all",
		"credential.https://github.com.helper"
	], stateDir, AbortSignal.any([signal, AbortSignal.timeout(6e4)])).catch(() => "")).split("\0").join("\0") !== [
		`file:${workerGitConfig(stateDir)}`,
		credentialHelper(github.cli),
		""
	].join("\0")) throw new SetupError("gitTooOld");
}
/**
* Verifies that a ticket directory's local or worktree git config defines no custom `credential.*` or `http.*extraheader`
* keys, which the agent's git would read from the repository's own config and act on.
*/
async function verifyDirectory(directory, subprocess, signal) {
	const scoped = (await runAsWorker(subprocess, [
		"git",
		"config",
		"-z",
		"--show-scope",
		"--get-regexp",
		"^(credential\\..*|http\\..*extraheader)$"
	], directory, AbortSignal.any([signal, AbortSignal.timeout(6e4)])).catch((error) => {
		if (error instanceof CliError && error.exitCode === 1) return "";
		throw error;
	})).split("\0");
	const local = scoped.flatMap((scope, index) => index % 2 === 0 && (scope === "local" || scope === "worktree") ? [scoped[index + 1].split("\n")[0]] : []);
	if (local.length) throw new Error(`The git configuration of the repository in ${directory} sets ${local.join(", ")}, which the agent's git would also read; remove them.`);
}
//#endregion
//#region src/deployment.ts
/** Plugin configuration and startup verification for repository access and agent CLI identities. */
const reason = (error) => error instanceof Error ? error.message : String(error);
const absolute = (description) => s.string().pattern(/^\//).description(`${description} Absolute path.`);
/** Plugin configuration of the dsh-superagent entry. Volatile fields apply without a restart because dsh-superagent reads them on each use; changing `stateDir` remounts the plugin. */
const Config = s.object({
	stateDir: absolute("Directory for the database, locks, worker shims, the agent's git configuration and, by default, the ticket directories.").required(),
	promptMaxChars: s.number().min(LIMITS.promptMaxChars.min).max(LIMITS.promptMaxChars.max).step(1).default(1e5).description("Largest saved prompt configuration, in characters.").volatile(),
	admissionContextMaxPages: s.number().min(LIMITS.admissionContextMaxPages.min).max(LIMITS.admissionContextMaxPages.max).step(1).default(10).description("Pages of thread context one assessment may read.").volatile(),
	admissionContextTimeoutMs: s.number().min(LIMITS.admissionContextTimeoutMs.min).max(LIMITS.admissionContextTimeoutMs.max).step(1).default(15e3).description("Time limit of one context read during an assessment, in milliseconds.").volatile()
});
const MOVED = {
	repository: "on the GitHub Source",
	branchPrefix: "in the prepare command of the Execution settings",
	github: "on the GitHub Source",
	feishu: "on the Feishu Source",
	author: "prompt text",
	repositoryPath: "in the prepare command of the Execution settings",
	worktreeRoot: "the ticket directory of the Execution settings",
	blockedCommands: "in the Execution settings"
};
/** Read machine settings and reject unknown configuration keys (naming where deprecated keys moved). */
function machineOf(config) {
	const unknown = Object.keys(config).filter((key) => !(key in (Config.dict ?? {})));
	if (unknown.length) throw new Error(`dsh-superagent configuration has keys it does not use: ${unknown.map((key) => MOVED[key] ? `${key} (now ${MOVED[key]})` : key).join(", ")}; docs/006-deployment.md lists the keys`);
	const { stateDir, promptMaxChars, admissionContextMaxPages, admissionContextTimeoutMs } = config;
	return {
		stateDir,
		promptMaxChars,
		admissionContextMaxPages,
		admissionContextTimeoutMs
	};
}
const GithubAccountsSchema = z.object({
	repository: z.string().trim().regex(/^([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?$/, "owner/name").default(""),
	cli: z.string().trim().default("")
});
const FeishuBotSchema = z.object({ cli: z.string().trim().default("") });
/** Source configuration keys that affect deployment setup and trigger a restart when changed. */
const SETUP_FIELDS = {
	github: Object.keys(GithubAccountsSchema.shape),
	feishu: Object.keys(FeishuBotSchema.shape)
};
/** Resolve a command name or absolute path to an executable file, ignoring the worker shim directory. */
function executable(name, path, exclude) {
	if (name.includes("/") && !isAbsolute(name)) throw new Error(`${name} must be a command name or an absolute path`);
	const candidates = isAbsolute(name) ? [name] : path.split(delimiter).filter((dir) => isAbsolute(dir) && !(exclude && sameDirectory(dir, exclude))).map((dir) => join(dir, name));
	for (const candidate of candidates) try {
		if (statSync(candidate).isFile()) {
			accessSync(candidate, constants.X_OK);
			return candidate;
		}
	} catch {}
	throw new Error(`${name} is not an executable file${isAbsolute(name) ? "" : " on PATH"}`);
}
/** Run startup checks through DSH's worker subprocess service with worker shims removed from PATH so a `gh` wrapper script reaches the real binary. */
function workerProbe(subprocess, stateDir, cwd, signal) {
	const path = withoutDirectory(process.env.PATH ?? "", workerBin(stateDir));
	return (argv) => runAsWorker(subprocess, [
		"env",
		`PATH=${path}`,
		...argv
	], cwd, AbortSignal.any([signal, AbortSignal.timeout(6e4)]));
}
const GithubUser = z.object({
	login: z.string().regex(/^[A-Za-z0-9-]+$/),
	id: z.number().int().positive()
});
const RepositoryAccess = z.object({
	name: z.string().regex(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/),
	push: z.boolean().nullable()
});
function parsed(schema, text) {
	let value;
	try {
		value = JSON.parse(text);
	} catch {
		return;
	}
	const result = schema.safeParse(value);
	return result.success ? result.data : void 0;
}
/** Verify the agent's GitHub CLI identity and push access to the configured repository. */
async function resolveDeployment(machine, github, probe, path = process.env.PATH ?? "") {
	const { stateDir } = machine;
	const accounts = GithubAccountsSchema.parse(github ?? {});
	const remote = accounts.repository;
	if (!remote) throw new SetupError("repositoryUnset");
	if (!accounts.cli) throw new SetupError("agentCliUnset");
	let cli;
	try {
		cli = executable(accounts.cli, path, workerBin(stateDir));
	} catch (error) {
		throw new SetupError("agentCliMissing", { output: reason(error) });
	}
	const text = await probe([
		cli,
		"api",
		"user"
	]).catch((error) => {
		throw new SetupError("agentCliSignedOut", { output: reason(error) });
	});
	const agent = parsed(GithubUser, text);
	if (!agent) throw new SetupError("agentCliNoAccount");
	const access = parsed(RepositoryAccess, await probe([
		cli,
		"api",
		`repos/${remote}`,
		"--jq",
		"{name: .full_name, push: .permissions.push}"
	]).catch((error) => {
		throw new SetupError("repositoryUnreadable", {
			account: agent.login,
			repository: remote,
			output: reason(error)
		});
	}));
	if (!access) throw new SetupError("repositoryUnreported", { repository: remote });
	const repository = access.name;
	if (access.push !== true) throw new SetupError("repositoryReadOnly", {
		account: agent.login,
		repository
	});
	return {
		...machine,
		repository,
		github: {
			cli,
			login: agent.login,
			noreply: `${agent.id}+${agent.login}@users.noreply.github.com`
		}
	};
}
const AuthStatus = z.object({
	appId: z.string().regex(/^cli_[A-Za-z0-9]+$/),
	brand: z.enum(["feishu", "lark"]).default("feishu"),
	identities: z.object({ bot: z.object({ status: z.string() }) })
});
const BotInfo = z.object({ bot: z.object({
	open_id: z.string().regex(/^ou_[A-Za-z0-9]+$/),
	app_name: z.string().default("")
}) });
/**
* Verify that the configured Feishu CLI is authenticated as a bot and restricted to strict mode `bot`.
* Workers invoke this CLI as `lark-cli`, so a CLI that also permits a user identity would let workers act as that user.
*/
async function resolveFeishuBot(machine, feishu, probe, path = process.env.PATH ?? "") {
	const { cli: name } = FeishuBotSchema.parse(feishu ?? {});
	if (!name) return void 0;
	const fail = (error) => {
		throw error instanceof SetupError ? error : new SetupError("feishuCliFailed", { output: reason(error) });
	};
	let cli = "";
	try {
		cli = executable(name, path, workerBin(machine.stateDir));
	} catch (error) {
		fail(error);
	}
	const run = (...args) => probe([
		"env",
		"LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1",
		"LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1",
		cli,
		...args
	]).catch(fail);
	const text = await run("auth", "status");
	const status = parsed(AuthStatus, text.slice(text.indexOf("{")));
	if (!status) return fail(new SetupError("feishuNoApp"));
	if (status.identities.bot.status !== "ready") fail(new SetupError("feishuBotNotReady", {
		app: status.appId,
		status: status.identities.bot.status
	}));
	const mode = /strict-mode:\s*(\w+)/.exec(await run("config", "strict-mode"))?.[1];
	if (mode !== "bot") fail(new SetupError("feishuUserIdentity", { mode: mode ?? "unknown" }));
	const info = parsed(BotInfo, (await run("api", "GET", "/open-apis/bot/v3/info", "--as", "bot", "--format", "ndjson")).split("\n")[0] ?? "");
	if (!info) return fail(new SetupError("feishuNoBot"));
	return {
		cli,
		appId: status.appId,
		brand: status.brand,
		botId: info.bot.open_id,
		name: info.bot.app_name
	};
}
//#endregion
//#region src/sources/poll.ts
/** Shared polling helpers for subscribed threads, overlap-safe cursors, and timer-friendly delays. */
/** How long a subscribed Thread with no live Ticket continues to be polled after its last Trigger or Ticket end. */
const POLL_HORIZON_MS = 12096e5;
/** True when a subscribed thread has a live ticket or recent activity/completion within `POLL_HORIZON_MS`. */
function polled(ctx, thread, now = Date.now()) {
	const tickets = thread.subscriptions.map((id) => ctx.tickets.get(id));
	if (tickets.some((ticket) => !!ticket && liveTicket(ticket))) return true;
	const times = [thread.lastAt ?? thread.createdAt, ...tickets.map((ticket) => ticket?.ended?.at ?? "")].map(Date.parse).filter(Number.isFinite);
	return now - Math.max(...times) < POLL_HORIZON_MS;
}
/** Steps a poll start timestamp back by 5 seconds so late-arriving remote events are not missed; deterministic trigger IDs deduplicate overlaps. */
const cursorAt = (started) => (/* @__PURE__ */ new Date(Date.parse(started) - 5e3)).toISOString();
/** Polls each subscribed Thread of `source` within the horizon independently; records failures on the Thread as `pollError` (unless `stopped()`) and clears `pollError` on success. */
async function pollThreads(ctx, source, stopped, poll, skip = () => false) {
	for (const thread of ctx.threads.subscribed(source)) {
		if (stopped()) return;
		if (skip(thread) || !polled(ctx, thread)) continue;
		try {
			await poll(thread);
			ctx.threads.patch(thread.key, { pollError: void 0 });
		} catch (error) {
			if (stopped()) return;
			ctx.threads.patch(thread.key, { pollError: String(error) });
		}
	}
}
/** Waits `ms` or until `signal` aborts using global `setTimeout` so test fake timers can drive polling loops. */
function pause(ms, signal) {
	return new Promise((resolve) => {
		if (signal.aborted) {
			resolve();
			return;
		}
		const stop = () => {
			clearTimeout(timer);
			resolve();
		};
		const timer = setTimeout(() => {
			signal.removeEventListener("abort", stop);
			resolve();
		}, ms);
		signal.addEventListener("abort", stop, { once: true });
	});
}
//#endregion
export { CliError as C, LIMITS as D, SetupError as E, key as O, writeEnvironment as S, validItems as T, runAsWorker as _, polled as a, withoutDirectory as b, GithubAccountsSchema as c, resolveDeployment as d, resolveFeishuBot as f, applyEnvironment as g, agentVariables as h, pollThreads as i, SETUP_FIELDS as l, WORKER_COMMANDS as m, cursorAt as n, Config as o, workerProbe as p, pause as r, FeishuBotSchema as s, POLL_HORIZON_MS as t, machineOf as u, verifyDirectory as v, Commands as w, workerBin as x, verifyEnvironment as y };
