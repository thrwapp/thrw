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
    const bodyText = await buttondownResponse.text().catch(() => "<unreadable body>");

    // Confirmed live: Buttondown returns this specific documented error
    // code (https://docs.buttondown.com/api-error-codes#email_already_exists)
    // when the address already exists - not a real failure, just someone
    // re-submitting (or already on the list from elsewhere). Treat it as
    // success rather than showing a scary error for something that isn't
    // actually wrong.
    let code: unknown;
    try {
      code = (JSON.parse(bodyText) as Record<string, unknown>)?.code;
    } catch {
      // bodyText wasn't JSON - fall through, code stays undefined, and
      // this is handled as a real failure below.
    }
    if (code === "email_already_exists") {
      return jsonResponse({ ok: true }, 200);
    }

    console.error(
      `waitlist: Buttondown returned ${buttondownResponse.status}`,
      bodyText,
    );
    return jsonResponse(
      { error: "Couldn't join the waitlist. Please try again." },
      502,
    );
  }

  return jsonResponse({ ok: true }, 200);
}
