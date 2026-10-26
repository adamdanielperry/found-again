// POST /api/story: emails a reader's recovery story to weio through the shared
// sendemail.weio.co.uk sender. The form works without JavaScript: success and
// failure both redirect back to a page on the site.
//
// Secrets (Cloudflare Pages → Settings → Variables and secrets):
//   SEND_EMAIL_AUTH  the sender's auth token

const SENDER = "https://sendemail.weio.co.uk/send";
const INBOX = "info@weio.co.uk";
const SITE = "https://foundagain.app/";
const ALLOWED_ORIGINS = [/^https:\/\/(www\.)?foundagain\.app$/, /^https:\/\/([\w-]+\.)?found-again\.pages\.dev$/, /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/];
const SOURCES = { app: "the app's success screen", tipped: "the page after a tip", site: "the website" };

const escapeHTML = (text) => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const field = (form, name, max) => String(form.get(name) ?? "").trim().slice(0, max);
const back = (request, path) => Response.redirect(new URL(path, request.url).toString(), 303);

export async function onRequestPost({ request, env }) {
  const origin = request.headers.get("Origin");
  if (origin && !ALLOWED_ORIGINS.some((pattern) => pattern.test(origin))) {
    return new Response("Forbidden", { status: 403 });
  }

  let form;
  try {
    form = await request.formData();
  } catch {
    return back(request, "/story?error=form");
  }

  // Bots fill the hidden "website" field; pretend it worked so they move on.
  if (field(form, "website", 200)) return back(request, "/story-sent");

  const story = field(form, "story", 5000);
  const name = field(form, "name", 100);
  const email = field(form, "email", 200);
  const share = form.get("share") === "yes";
  const source = SOURCES[field(form, "from", 20)] ?? SOURCES.site;
  if (story.length < 3) return back(request, "/story?error=empty");
  if (!env.SEND_EMAIL_AUTH) return back(request, "/story?error=send");

  const replyTo = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : INBOX;
  const consent = share ? "Yes, happy for it to be shared on foundagain.app" : "No, keep it private";
  const rows = [
    ["Name", name || "(not given)"],
    ["Email", email || "(not given)"],
    ["Share on website", consent],
    ["Sent from", source],
  ];

  const payload = new FormData();
  payload.set("auth", env.SEND_EMAIL_AUTH);
  payload.set("domain", SITE);
  payload.set("to", INBOX);
  payload.set("from", INBOX);
  payload.set("from_name", "Found Again");
  payload.set("replyto", replyTo);
  payload.set("subject", `Found Again story${name ? ` from ${name}` : ""}${share ? " (OK to share)" : ""}`);
  payload.set("body", `<p style="white-space:pre-wrap">${escapeHTML(story)}</p><hr><table>${rows.map(([k, v]) => `<tr><td><b>${k}</b></td><td>${escapeHTML(v)}</td></tr>`).join("")}</table>`);
  payload.set("text", `${story}\n\n---\n${rows.map(([k, v]) => `${k}: ${v}`).join("\n")}\n`);
  payload.set("is_safe", "1");

  try {
    const response = await fetch(SENDER, { method: "POST", body: payload });
    if (!response.ok) throw new Error(`sender returned ${response.status}: ${(await response.text()).slice(0, 200)}`);
  } catch (error) {
    console.error("story email failed", error);
    return back(request, "/story?error=send");
  }
  return back(request, "/story-sent");
}
