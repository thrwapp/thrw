// Cloudflare Pages Function: file-based routing maps this file to a POST
// handler at /waitlist. Keeps the Buttondown API key server-side — it is
// read from the BUTTONDOWN_API_KEY environment variable, which must be set
// in the Cloudflare Pages project's dashboard (see HANDOFF.md).
interface Env {
  BUTTONDOWN_API_KEY: string;
}

interface PagesContext {
  request: Request;
  env: Env;
}

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function jsonResponse(data: unknown, status: number): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export async function onRequestPost(context: PagesContext): Promise<Response> {
  const { request, env } = context;

  let email: unknown;
  try {
    const body = (await request.json()) as Record<string, unknown>;
    email = body?.email;
  } catch {
    return jsonResponse({ error: "Invalid request body." }, 400);
  }

  if (typeof email !== "string" || !EMAIL_PATTERN.test(email)) {
    return jsonResponse({ error: "Please enter a valid email address." }, 400);
  }

  if (!env.BUTTONDOWN_API_KEY) {
    return jsonResponse(
      { error: "Waitlist signups are temporarily unavailable." },
      500,
    );
  }

  let buttondownResponse: Response;
  try {
    buttondownResponse = await fetch(
      "https://api.buttondown.email/v1/subscribers",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Token ${env.BUTTONDOWN_API_KEY}`,
        },
        // Buttondown's API renamed this field from `email` to
        // `email_address` in a later API version - confirmed live via the
        // function's own error logging (422 field_renamed, "Use
        // `email_address` instead of `email`"). Sending the old name
        // isn't just ignored, it's a hard rejection.
        body: JSON.stringify({ email_address: email }),
      },
    );
  } catch (err) {
    // Logged (visible in Cloudflare Pages' Functions real-time logs / tail)
    // rather than surfaced to the caller - the client only ever sees the
    // generic message below, never Buttondown's own response, so this is
    // the only way to actually see why a submission failed in production.
    console.error("waitlist: fetch to Buttondown threw", err);
    return jsonResponse(
      { error: "Couldn't reach the waitlist service. Please try again." },
      502,
    );
  }

  if (!buttondownResponse.ok) {
    const body = await buttondownResponse.text().catch(() => "<unreadable body>");
    console.error(
      `waitlist: Buttondown returned ${buttondownResponse.status}`,
      body,
    );
    return jsonResponse(
      { error: "Couldn't join the waitlist. Please try again." },
      502,
    );
  }

  return jsonResponse({ ok: true }, 200);
}
