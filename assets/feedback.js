// feedback.js — wires the per-(cue, related) thumbs-up / thumbs-down widget
// to POST /_feedback, and persists the user's vote in sessionStorage so the
// UI keeps its "voted" state across same-tab navigations.
//
// Server expectations (matches lib/rhymecrime/store/feedback_store.rb):
//   POST /_feedback
//   Content-Type: application/json
//   { "cue": <string>, "related": <string>, "verdict": "up"|"down",
//     "session": <opaque per-tab id> }
// The server adds timestamp / IP / user-agent.
//
// We store one entry per (cue, related) in sessionStorage; clicking the
// already-active verdict UNDOES the vote (clears local state and posts
// verdict: "undo" so the audit trail records the retraction). Clicking
// the other direction overwrites the prior choice both locally and on
// the server (which is append-only — every click produces a new row, so
// the historical sequence is preserved on the backend even though the
// UI only shows the latest state).

(function () {
  "use strict";

  const STORAGE_PREFIX = "rc.feedback:";
  const SESSION_KEY = "rc.feedback.session";

  function sessionId() {
    let id = sessionStorage.getItem(SESSION_KEY);
    if (!id) {
      // crypto.randomUUID is widely available in modern browsers; fall
      // back to a non-cryptographic stamp if it isn't (prod is fine on
      // either; this is just a tab-scoped correlation id, not a secret).
      id = (window.crypto && crypto.randomUUID)
        ? crypto.randomUUID()
        : ("s_" + Date.now() + "_" + Math.random().toString(36).slice(2));
      sessionStorage.setItem(SESSION_KEY, id);
    }
    return id;
  }

  function storageKey(cue, related) {
    return STORAGE_PREFIX + cue + "\u241F" + related; // U+241F = unit separator
  }

  function loadVote(cue, related) {
    return sessionStorage.getItem(storageKey(cue, related));
  }

  function saveVote(cue, related, verdict) {
    sessionStorage.setItem(storageKey(cue, related), verdict);
  }

  function clearVote(cue, related) {
    sessionStorage.removeItem(storageKey(cue, related));
  }

  // After an undo, the cursor is still on top of the button, so the :hover
  // rule would keep the just-retracted thumb at full opacity — making the
  // undo invisible until you move the mouse. We tag the button with a class
  // that overrides the hover rule and tear the tag off the next time the
  // cursor leaves the button, restoring normal hover behavior afterwards.
  function suppressHoverUntilMouseLeave(button) {
    button.classList.add("suppress-hover");
    button.addEventListener("mouseleave", function handler() {
      button.classList.remove("suppress-hover");
      button.removeEventListener("mouseleave", handler);
    });
  }

  function applyVoteState(widget, verdict) {
    if (verdict === "up" || verdict === "down") {
      widget.dataset.feedback = verdict;
      widget.classList.add("has-vote");
    } else {
      delete widget.dataset.feedback;
      widget.classList.remove("has-vote");
    }
  }

  function hydrateExistingVotes(root) {
    root.querySelectorAll(".feedback-thumbs").forEach(function (widget) {
      const cue = widget.dataset.cue;
      const related = widget.dataset.related;
      if (!cue || !related) return;
      const prior = loadVote(cue, related);
      if (prior) applyVoteState(widget, prior);
    });
  }

  function postFeedback(cue, related, verdict) {
    return fetch("/_feedback", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        cue: cue,
        related: related,
        verdict: verdict,
        session: sessionId(),
      }),
      // Same-origin form; no credentials cookie needed, no CORS preflight.
      credentials: "omit",
      keepalive: true,
    });
  }

  function onClick(event) {
    const button = event.target.closest(".feedback-thumbs .thumb");
    if (!button) return;
    // Thumbs sit inside the same <a> wrapper as the rendered word, so we
    // have to swallow the navigation that would otherwise happen on click.
    event.preventDefault();
    event.stopPropagation();

    const widget = button.closest(".feedback-thumbs");
    if (!widget) return;
    const cue = widget.dataset.cue;
    const related = widget.dataset.related;
    if (!cue || !related) return;
    const clickedVerdict = button.classList.contains("thumb-up") ? "up" : "down";
    // Clicking your own active thumb retracts the vote; clicking the other
    // direction (or a fresh pair) lands a new verdict. We post the literal
    // action that just happened ("undo" / "up" / "down") so the server log
    // is a faithful click-stream rather than a normalized state diff.
    const wasActive = loadVote(cue, related) === clickedVerdict;
    const verdict = wasActive ? "undo" : clickedVerdict;

    if (wasActive) {
      applyVoteState(widget, null);
      clearVote(cue, related);
      suppressHoverUntilMouseLeave(button);
    } else {
      applyVoteState(widget, clickedVerdict);
      saveVote(cue, related, clickedVerdict);
    }

    postFeedback(cue, related, verdict).catch(function (err) {
      // Soft-fail: keep the optimistic UI state even on network error.
      // The user gets visible confirmation; if the request never lands we
      // miss one data point, which is an acceptable tradeoff for a
      // friction-minimal feedback widget.
      if (window.console && console.warn) {
        console.warn("rc.feedback: POST failed", err);
      }
    });
  }

  function init() {
    hydrateExistingVotes(document);
    document.addEventListener("click", onClick);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
