/**
 * ClickyJ Proxy Worker
 *
 * Proxies vision + streaming chat requests to the Google Gemini API so the
 * app never ships with a raw API key. The key is stored as a Cloudflare
 * secret. This is the only remaining proxy route in ClickyJ — speech-to-text
 * (WhisperKit) and text-to-speech (Kokoro) now run locally on the user's Mac,
 * so the former /tts and /transcribe-token routes have been removed.
 *
 * Route:
 *   POST /chat  → Gemini generateContent (streaming via SSE by default)
 *
 * The Swift client (GeminiAPI.swift) already sends a Gemini-shaped JSON body
 * (systemInstruction, contents, generationConfig). The Worker simply selects
 * the upstream model + endpoint, injects the key header, and forwards the
 * response (SSE body streamed straight through).
 */

interface Env {
  GEMINI_API_KEY: string;
}

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

// Allowlist of models the app may request, so a malformed/hostile header can't
// point the proxy at an arbitrary upstream path. Falls back to the default.
const ALLOWED_MODELS = new Set([
  "gemini-2.5-flash",
  "gemini-2.5-flash-lite",
]);
const DEFAULT_MODEL = "gemini-2.5-flash";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  // The app picks the model via the X-Clicky-Model header (set by GeminiAPI).
  const requestedModel = request.headers.get("X-Clicky-Model") ?? DEFAULT_MODEL;
  const model = ALLOWED_MODELS.has(requestedModel) ? requestedModel : DEFAULT_MODEL;

  // Streaming is the default. The app sets X-Clicky-Stream:false for the
  // non-streaming validation path (analyzeImage).
  const useStreaming = request.headers.get("X-Clicky-Stream") !== "false";
  const endpoint = useStreaming
    ? `${GEMINI_API_BASE}/${model}:streamGenerateContent?alt=sse`
    : `${GEMINI_API_BASE}/${model}:generateContent`;

  const upstreamResponse = await fetch(endpoint, {
    method: "POST",
    headers: {
      // Current/preferred auth method — keeps the key out of the URL.
      "x-goog-api-key": env.GEMINI_API_KEY,
      "content-type": "application/json",
    },
    body,
  });

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/chat] Gemini API error ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: upstreamResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Forward the body straight through. For streaming this is an SSE stream of
  // "data: {json}\n\n" lines that the Swift client reads incrementally; for the
  // non-streaming path it's a single JSON object.
  const contentType = useStreaming
    ? upstreamResponse.headers.get("content-type") || "text/event-stream"
    : upstreamResponse.headers.get("content-type") || "application/json";

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: {
      "content-type": contentType,
      "cache-control": "no-cache",
    },
  });
}
