import type { IncomingMessage, ServerResponse } from "node:http";
import type { ClineTaskSessionService, ClineTaskMessage } from "../cline-sdk/cline-task-session-service";
import type { ResolvedClineLaunchConfig } from "../cline-sdk/cline-provider-service";
import { createHomeAgentSessionId } from "../core/home-agent-session";
import type { RuntimeTaskSessionSummary } from "../core/api-contract";
import { loadWorkspaceContextById } from "../state/workspace-state";

interface OpenAiCompatDeps {
	getScopedClineTaskSessionService: (scope: { workspaceId: string; workspacePath: string }) => Promise<ClineTaskSessionService>;
	resolveLaunchConfig: () => Promise<ResolvedClineLaunchConfig>;
}

const OPENAI_ROUTE_RE = /^\/([a-z0-9][a-z0-9-]*)\/v1\/chat\/completions$/;

export function matchOpenAiCompatRoute(pathname: string): string | null {
	const match = OPENAI_ROUTE_RE.exec(pathname);
	return match ? match[1] : null;
}

function createErrorResponse(message: string, type: string, status: number, res: ServerResponse): void {
	res.writeHead(status, { "Content-Type": "application/json" });
	res.end(JSON.stringify({ error: { message, type } }));
}

function createChatChunk(id: string, delta: Record<string, unknown>, finishReason: string | null): string {
	const chunk: Record<string, unknown> = {
		id,
		object: "chat.completion.chunk",
		created: Math.floor(Date.now() / 1000),
		model: "cline",
		choices: [{ index: 0, delta, finish_reason: finishReason }],
	};
	return `data: ${JSON.stringify(chunk)}\n\n`;
}

function validateAuth(req: IncomingMessage): boolean {
	const apiKey = process.env.KANBAN_API_KEY;
	if (!apiKey) return true;
	const authHeader = req.headers.authorization;
	if (!authHeader?.startsWith("Bearer ")) return false;
	return authHeader.slice(7) === apiKey;
}

interface ParsedOpenAiRequest {
	text: string;
	images?: string[];
}

function parseOpenAiRequest(body: unknown): ParsedOpenAiRequest {
	if (!body || typeof body !== "object") throw { message: "Invalid JSON", type: "invalid_request_error", status: 400 };
	const obj = body as Record<string, unknown>;
	if (obj.stream === false) throw { message: "Only streaming is supported (set stream: true)", type: "invalid_request_error", status: 400 };
	const messages = obj.messages;
	if (!Array.isArray(messages) || messages.length === 0) throw { message: "messages is required and must be non-empty", type: "invalid_request_error", status: 400 };
	let lastUserText: string | null = null;
	let images: string[] | undefined;
	for (let i = messages.length - 1; i >= 0; i--) {
		const msg = messages[i];
		if (msg && typeof msg === "object" && (msg as Record<string, unknown>).role === "user") {
			const content = (msg as Record<string, unknown>).content;
			if (typeof content === "string" && content.trim()) {
				lastUserText = content.trim();
				break;
			}
		}
	}
	if (!lastUserText) throw { message: "At least one user message with non-empty content is required", type: "invalid_request_error", status: 400 };
	return { text: lastUserText, images };
}

function readBody(req: IncomingMessage, maxBytes = 1_048_576): Promise<string> {
	return new Promise((resolve, reject) => {
		let body = "";
		let size = 0;
		req.on("data", (chunk: Buffer) => {
			size += chunk.length;
			if (size > maxBytes) {
				reject(new Error("Request body too large"));
				return;
			}
			body += chunk.toString("utf8");
		});
		req.on("end", () => resolve(body));
		req.on("error", reject);
	});
}

export async function handleOpenAiCompatRequest(
	req: IncomingMessage,
	res: ServerResponse,
	projectSlug: string,
	deps: OpenAiCompatDeps,
): Promise<void> {
	try {
		if (!validateAuth(req)) {
			createErrorResponse("Unauthorized", "authentication_error", 401, res);
			return;
		}

		let rawBody: string;
		try {
			rawBody = await readBody(req);
		} catch {
			createErrorResponse("Request body too large", "invalid_request_error", 400, res);
			return;
		}

		let parsed: unknown;
		try {
			parsed = JSON.parse(rawBody);
		} catch {
			createErrorResponse("Invalid JSON", "invalid_request_error", 400, res);
			return;
		}

		let request: ParsedOpenAiRequest;
		try {
			request = parseOpenAiRequest(parsed);
		} catch (err: unknown) {
			const e = err as { message: string; type: string; status: number };
			createErrorResponse(e.message, e.type, e.status, res);
			return;
		}

		const workspaceContext = await loadWorkspaceContextById(projectSlug);
		if (!workspaceContext) {
			createErrorResponse(`Project not found: ${projectSlug}`, "not_found_error", 404, res);
			return;
		}

		const scope = { workspaceId: workspaceContext.workspaceId, workspacePath: workspaceContext.repoPath };
		const service = await deps.getScopedClineTaskSessionService(scope);
		const taskId = createHomeAgentSessionId(workspaceContext.workspaceId, "cline");

		let summary: RuntimeTaskSessionSummary | null = await service.sendTaskSessionInput(taskId, request.text);
		if (!summary) {
			if (service.getSummary(taskId)?.state === "running") {
				createErrorResponse("Agent is busy, try again later", "rate_limit_error", 429, res);
				return;
			}
			const launchConfig = await deps.resolveLaunchConfig();
			summary = await service.startTaskSession({
				taskId,
				cwd: workspaceContext.repoPath,
				prompt: request.text,
				images: request.images,
				resumeFromPersistence: true,
				providerId: launchConfig.providerId,
				modelId: launchConfig.modelId,
				apiKey: launchConfig.apiKey,
				baseUrl: launchConfig.baseUrl,
				reasoningEffort: launchConfig.reasoningEffort,
			});
		}

		res.writeHead(200, {
			"Content-Type": "text/event-stream",
			"Cache-Control": "no-cache",
			Connection: "keep-alive",
			"X-Accel-Buffering": "no",
		});

		const chatId = `chatcmpl-${taskId}`;
		res.write(createChatChunk(chatId, { role: "assistant" }, null));

		let sentContent = false;
		let finished = false;

		const cleanup = () => {
			finished = true;
			unsubscribeMessage();
			unsubscribeSummary();
		};

		const onFinish = (reason: string) => {
			if (finished) return;
			cleanup();
			if (!sentContent) {
				res.write(createChatChunk(chatId, { content: "" }, null));
			}
			res.write(createChatChunk(chatId, {}, reason));
			res.write("data: [DONE]\n\n");
			res.end();
		};

		const onMessage = (msgTaskId: string, message: ClineTaskMessage) => {
			if (msgTaskId !== taskId || finished) return;
			if (message.role === "assistant" && message.content) {
				sentContent = true;
				res.write(createChatChunk(chatId, { content: message.content }, null));
			}
		};

		const onSummary = (s: RuntimeTaskSessionSummary) => {
			if (s.taskId !== taskId || finished) return;
			if (s.state === "idle") {
				onFinish("stop");
			} else if (s.state === "awaiting_review") {
				onFinish("stop");
			} else if (s.state === "failed") {
				onFinish("stop");
			}
		};

		const unsubscribeMessage = service.onMessage(onMessage);
		const unsubscribeSummary = service.onSummary(onSummary);

		req.on("close", () => {
			if (!finished) {
				cleanup();
			}
		});

		const currentSummary = service.getSummary(taskId);
		if (currentSummary && currentSummary.state !== "running") {
			onFinish("stop");
		}
	} catch (error) {
		const message = error instanceof Error ? error.message : "Internal server error";
		if (!res.headersSent) {
			createErrorResponse(message, "server_error", 500, res);
		} else {
			try {
				res.write(createChatChunk("chatcmpl-error", { content: `\n\nError: ${message}` }, "stop"));
				res.write("data: [DONE]\n\n");
			} catch {}
			res.end();
		}
	}
}
