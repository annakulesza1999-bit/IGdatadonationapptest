/* Runs in WebKit's isolated client world. It observes visible media and actions.
   It reads comment text only when the user submits a comment. It never reads
   password fields, cookies, messages, or request headers. */
(() => {
  if (!["instagram.com", "www.instagram.com"].includes(location.hostname)) return;
  if (window.__instagramCaptureObserverV7) return;
  window.__instagramCaptureObserverV7 = true;
  window.__feedWindowEnabled = false;

  const cards = new Map();
  const videos = new WeakSet();
  const videoTimes = new WeakMap();
  const recentActions = new Map();
  const postPath = /^\/(p|reel)\/([A-Za-z0-9_-]{1,64})\/?$/;
  const accountPath = /^\/([A-Za-z0-9._]{1,30})\/?$/;
  let lastStatus = 0;
  let commentContext = null;

  function newObservationId() {
    if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, character => {
      const value = Math.floor(Math.random() * 16);
      return (character === "x" ? value : (value & 3) | 8).toString(16);
    });
  }

  // Compare a CDN filename, its media ID, and Instagram's cache ID. No URL is stored.
  function assetKeys(raw) {
    try {
      const url = new URL(raw, location.href);
      if (url.protocol !== "https:" ||
          !/^(?:[a-z0-9-]+\.)*(?:cdninstagram\.com|fbcdn\.net)$/i.test(url.hostname)) return [];
      const name = url.pathname.split("/").pop() || "";
      const keys = [];
      if (/^[A-Za-z0-9._-]{8,145}$/.test(name)) keys.push("f_" + name.toLowerCase());
      const number = /^(\d{8,20})(?:_|\.)/.exec(name);
      if (number) keys.push("m_" + number[1]);
      const cached = url.searchParams.get("ig_cache_key");
      if (/^[A-Za-z0-9_-]{16,120}$/.test(cached || "")) keys.push("c_" + cached);
      return keys;
    } catch (_) { return []; }
  }

  function mediaIdKeys(node) {
    const keys = [];
    for (const attribute of ["data-media-id", "data-post-id", "data-instagram-media-id"]) {
      const match = /^(\d{8,20})(?:_\d{1,20})?$/.exec(node.getAttribute?.(attribute) || "");
      if (match) keys.push("i_" + match[1]);
    }
    return keys;
  }

  function mediaKeysOf(card) {
    const keys = new Set();
    for (const node of [card, ...card.querySelectorAll(
      "[data-media-id], [data-post-id], [data-instagram-media-id]")]) {
      for (const key of mediaIdKeys(node)) keys.add(key);
    }
    for (const media of card.querySelectorAll("img, video")) {
      const box = media.getBoundingClientRect?.();
      if (!box || box.width < 160 || box.height < 160) continue;
      for (const url of [media.currentSrc, media.src, media.poster]) {
        for (const key of assetKeys(url)) keys.add(key);
      }
      if (keys.size >= 24) break;
    }
    return [...keys].slice(0, 24);
  }

  function identityKeysOf(card) {
    const candidates = [...card.querySelectorAll("video, img")].filter(candidate => {
      const box = candidate.getBoundingClientRect?.();
      return box?.width >= 160 && box?.height >= 160;
    });
    const media = candidates.find(candidate => candidate.tagName === "VIDEO") || candidates[0];
    if (!media) return mediaIdKeys(card);
    const source = media.tagName === "VIDEO"
      ? media.poster || media.currentSrc || media.src
      : media.currentSrc || media.src;
    return [...new Set([...assetKeys(source), ...mediaIdKeys(card), ...mediaIdKeys(media)])];
  }

  // A local-only fallback for media without an Instagram CDN ID (for example,
  // blob video URLs). The source URL is never sent to native code or exported.
  function fingerprintOf(card) {
    const choices = [...card.querySelectorAll("video, img")]
      .map(media => ({ media, box: media.getBoundingClientRect?.() }))
      .filter(choice => choice.box?.width >= 160 && choice.box?.height >= 160)
      .sort((a, b) => b.box.width * b.box.height - a.box.width * a.box.height);
    const media = (choices.find(choice => choice.media.tagName === "VIDEO") ||
      choices[0])?.media;
    const raw = media?.tagName === "VIDEO"
      ? media.poster || media.currentSrc || media.src
      : media?.currentSrc || media?.src;
    if (!raw) return "";
    try {
      const url = new URL(raw, location.href);
      if (!["https:", "blob:"].includes(url.protocol)) return "";
      let hash = 2166136261;
      const value = url.origin + url.pathname;
      for (let index = 0; index < value.length; index++) {
        hash = Math.imul(hash ^ value.charCodeAt(index), 16777619);
      }
      return (hash >>> 0).toString(16);
    } catch (_) { return ""; }
  }

  function substantialMedia(card) {
    for (const media of card.querySelectorAll("video, img")) {
      const box = media.getBoundingClientRect?.();
      if (box && box.width >= 160 && box.height >= 160) return true;
    }
    return false;
  }

  function send(data) {
    try { window.webkit.messageHandlers.donation.postMessage(data); } catch (_) {}
  }

  function surface() {
    if (location.pathname === "/") return "Home";
    if (/^\/reels?\//.test(location.pathname)) return "Reels";
    if (/^\/p\/[A-Za-z0-9_-]+\/?$/.test(location.pathname)) return "Post";
    return null;
  }

  function pathOf(link) {
    try {
      const url = new URL(link.getAttribute("href") || "", location.href);
      return ["instagram.com", "www.instagram.com"].includes(url.hostname) ? url.pathname : "";
    } catch (_) { return ""; }
  }

  function canonicalPostLink(raw) {
    try {
      const url = new URL(raw, location.href);
      if (!["instagram.com", "www.instagram.com"].includes(url.hostname)) return null;
      const match = postPath.exec(url.pathname);
      return match ? `https://www.instagram.com/${match[1]}/${match[2]}/` : null;
    } catch (_) { return null; }
  }

  function linkOf(card) {
    if (/^\/(p|reel)\//.test(location.pathname)) {
      const match = postPath.exec(location.pathname);
      if (match) return `https://www.instagram.com/${match[1]}/${match[2]}/`;
    }
    const mediaLinks = new Set([...card.querySelectorAll("video, img")]
      .filter(media => {
        const box = media.getBoundingClientRect?.();
        return box?.width >= 160 && box?.height >= 160;
      })
      .map(media => canonicalPostLink(media.closest?.("a[href]")?.getAttribute?.("href")))
      .filter(Boolean));
    if (mediaLinks.size === 1) return [...mediaLinks][0];
    const timeLinks = new Set([...card.querySelectorAll("time")]
      .map(time => canonicalPostLink(time.closest?.("a[href]")?.getAttribute?.("href")))
      .filter(Boolean));
    if (timeLinks.size === 1) return [...timeLinks][0];
    const anchors = card.matches?.("a[href]")
      ? [card, ...card.querySelectorAll("a[href]")]
      : card.querySelectorAll("a[href]");
    const links = new Set([...anchors].map(anchor =>
      canonicalPostLink(anchor.getAttribute?.("href"))).filter(Boolean));
    if (links.size === 1) return [...links][0];
    // Some cards expose a direct post URL as an attribute rather than an anchor.
    const explicit = new Set();
    for (const node of [card, ...card.querySelectorAll(
      "[data-permalink], [data-post-url], [data-media-permalink]")]) {
      for (const key of ["data-permalink", "data-post-url", "data-media-permalink"]) {
        const link = canonicalPostLink(node.getAttribute?.(key));
        if (link) explicit.add(link);
      }
    }
    if (explicit.size === 1) return [...explicit][0];
    // Some feed variants retain the shortcode on a card without a post anchor.
    const shortcodes = new Set();
    for (const node of [card, ...card.querySelectorAll(
      "[data-shortcode], [data-media-shortcode], [data-post-shortcode]")]) {
      const code = ["data-shortcode", "data-media-shortcode", "data-post-shortcode"]
        .map(key => node.getAttribute?.(key))
        .find(value => typeof value === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(value));
      if (code) shortcodes.add(code);
    }
    if (shortcodes.size === 1) {
      const code = [...shortcodes][0];
      const matching = [...links].filter(link => link.endsWith(`/${code}/`));
      if (matching.length === 1) return matching[0];
      if (links.size > 1) return null;
      return `https://www.instagram.com/${surface() === "Reels" ? "reel" : "p"}/${code}/`;
    }
    return null;
  }

  function cardFor(anchor) {
    const article = anchor.closest("article, [role='article']");
    if (article) return article;
    let node = anchor;
    for (let depth = 0; node && depth < 7; depth++, node = node.parentElement) {
      if (node.matches?.("main, [role='main'], body")) break;
      if (node.querySelector?.("video, img") && node.getBoundingClientRect().height >= 160) {
        return node;
      }
    }
    return null;
  }

  function cardForMedia(media) {
    const article = media.closest?.("article, [role='article']");
    if (article) return article;
    let node = media.parentElement;
    for (let depth = 0; node && depth < 9; depth++, node = node.parentElement) {
      if (node.matches?.("main, [role='main'], body")) break;
      const controls = node.querySelectorAll?.("button, [role='button']") || [];
      const hasAccount = [...(node.querySelectorAll?.("a[href]") || [])]
        .some(anchor => accountPath.test(pathOf(anchor)));
      if (controls.length >= 2 && (hasAccount || node.querySelector?.("header"))) {
        return node;
      }
    }
    return null;
  }

  function accountOf(card) {
    const header = card.querySelector("header") || card;
    const blocked = new Set(["explore", "reels", "reel", "direct", "accounts", "p", "stories",
      "following", "follow", "suggested", "sponsored", "gesponsert", "anzeige", "instagram"]);
    const handles = area => new Set([...area.querySelectorAll("a[href]")]
      .map(anchor => accountPath.exec(pathOf(anchor))?.[1])
      .filter(value => value && !blocked.has(value.toLowerCase())));
    const inHeader = handles(header);
    if (inHeader.size === 1) return [...inHeader][0];
    for (const area of [header, card]) {
      const direct = new Set();
      for (const node of [area, ...area.querySelectorAll(
        "[data-username], [data-user-name], [data-owner-username]")]) {
        for (const key of ["data-username", "data-user-name", "data-owner-username"]) {
          const value = node.getAttribute?.(key);
          if (/^[A-Za-z0-9._]{1,30}$/.test(value || "") &&
              !blocked.has(value.toLowerCase())) direct.add(value);
        }
      }
      if (direct.size === 1) return [...direct][0];
    }
    const all = handles(card);
    if (all.size === 1) return [...all][0];
    // On some mobile cards the author is plain header text, without a link.
    const firstLine = (header.innerText || "").split("\n")[0].trim();
    const textHandle = /^@?([A-Za-z0-9._]{1,30})(?:\s+(?:Following|Follow|Suggested|Sponsored))?$/i
      .exec(firstLine)?.[1];
    if (textHandle && !blocked.has(textHandle.toLowerCase())) return textHandle;
    return "";
  }

  function labelOf(card) {
    const heading = (card.querySelector("header")?.innerText || card.innerText || "").slice(0, 260);
    if (/\b(sponsored|gesponsert|patrocinado|sponsorisé|anzeige|werbung)\b/i.test(heading)) {
      return "Sponsored";
    }
    if (/\b(suggested for you|suggested|vorgeschlagen|empfohlen|sugerido)\b/i.test(heading)) {
      return "Suggested";
    }
    return "Post";
  }

  function relationshipOf(card, label) {
    const heading = card.querySelector("header") || card;
    const controls = [...heading.querySelectorAll("button, [role='button']")]
      .map(element => (element.innerText || element.getAttribute("aria-label") || "").trim());
    if (controls.some(text => /^(following|gefolgt|abonniert|siguiendo)$/i.test(text))) {
      return "Followed";
    }
    if (label === "Suggested") return "Suggested";
    if (controls.some(text => /^(follow|folgen|suivre|seguir)$/i.test(text))) {
      return "Not followed";
    }
    return "Unknown";
  }

  function visible(card) {
    if (!card.isConnected || document.visibilityState !== "visible" || !surface()) return false;
    const box = card.getBoundingClientRect();
    const height = Math.max(0, Math.min(box.bottom, innerHeight) - Math.max(box.top, 0));
    const width = Math.max(0, Math.min(box.right, innerWidth) - Math.max(box.left, 0));
    return box.width > 0 && box.height > 0 &&
      height >= Math.min(190, box.height * 0.3) &&
      width >= Math.min(120, box.width * 0.5);
  }

  function captionOf(card) {
    const node = card.querySelector(
      "[data-testid='post-caption'], [data-testid='caption'], h1"
    );
    const text = (node?.innerText || node?.textContent || "").trim();
    return text.slice(0, 5000);
  }

  function dataFor(state, detailed = false) {
    const data = { permalink: state.permalink || "", observationId: state.observationId };
    if (!detailed) return data;
    const label = labelOf(state.element);
    const video = state.element.querySelector("video");
    Object.assign(data, { mediaKeys: state.mediaKeys,
      account: state.account || accountOf(state.element), label,
      relationship: relationshipOf(state.element, label),
      surface: surface() || "Home",
      isVideo: !!video || (state.permalink || "").includes("/reel/") });
    const caption = captionOf(state.element);
    if (caption) {
      data.caption = caption;
      data.hashtags = [...new Set(caption.match(/#[\p{L}\p{N}_]{1,100}/gu) || [])].slice(0, 100);
    }
    if (Number.isFinite(video?.duration) && video.duration > 0) {
      data.videoDuration = video.duration;
    }
    return data;
  }

  function scan() {
    if (!surface()) return;
    const candidates = new Set();
    for (const article of document.querySelectorAll("main article, article, [role='article']")) {
      if (linkOf(article) || substantialMedia(article)) candidates.add(article);
    }
    for (const anchor of document.querySelectorAll("main a[href], [role='main'] a[href]")) {
      if (!postPath.test(pathOf(anchor))) continue;
      const card = cardFor(anchor);
      if (card) candidates.add(card);
    }
    for (const media of document.querySelectorAll(
      "main video, main img, [role='main'] video, [role='main'] img")) {
      const box = media.getBoundingClientRect?.();
      if (box?.width < 160 || box?.height < 160) continue;
      const card = cardForMedia(media);
      if (card) candidates.add(card);
    }
    if (/^\/(p|reel)\//.test(location.pathname)) {
      for (const video of document.querySelectorAll("video")) {
        const card = video.closest("article, [role='article']") ||
          video.parentElement?.parentElement || video.parentElement;
        if (card) candidates.add(card);
      }
      if (candidates.size === 0) {
        const main = document.querySelector("main, [role='main']");
        if (main && main.querySelector("img, video")) candidates.add(main);
      }
      if (candidates.size > 1) {
        const choices = [...candidates];
        const first = choices.find(card => card.querySelector("video")) ||
          choices.find(card => card.querySelector("img")) || choices[0];
        candidates.clear();
        candidates.add(first);
      }
    }
    for (const element of candidates) {
      const permalink = linkOf(element);
      const keys = identityKeysOf(element);
      const fingerprint = fingerprintOf(element);
      const account = accountOf(element);
      const existing = cards.get(element);
      const linkChanged = existing?.permalink && permalink && existing.permalink !== permalink;
      const differentKeys = existing?.mediaKeys.length && keys.length &&
        !existing.mediaKeys.some(key => keys.includes(key));
      const differentFallback = existing?.fingerprint && fingerprint &&
        existing.fingerprint !== fingerprint &&
        !existing.mediaKeys.length && !keys.length;
      const changedWithoutLink = (!existing?.permalink || !permalink) &&
        (differentKeys || differentFallback);
      if (!existing || linkChanged || changedWithoutLink) {
        cards.set(element, {
          element, permalink, observationId: newObservationId(), account,
          mediaKeys: keys, fingerprint,
          since: null, lastTick: null, announced: false,
          buckets: new Set(), unsentBuckets: new Set()
        });
      } else {
        const oldAccount = existing.account;
        const oldLink = existing.permalink;
        if (permalink) existing.permalink = permalink;
        if (account) existing.account = account;
        if (fingerprint) existing.fingerprint = fingerprint;
        existing.mediaKeys = [...new Set([...existing.mediaKeys, ...keys])].slice(-20);
        if (window.__feedWindowEnabled && existing.announced &&
            (existing.account !== oldAccount || existing.permalink !== oldLink)) {
          send({ event: "relationship", ...dataFor(existing, true) });
        }
      }
    }
    for (const [element, state] of cards) {
      if (!element.isConnected) {
        if (window.__feedWindowEnabled && state.announced && state.lastTick != null) {
          const seconds = Math.min(3, (Date.now() - state.lastTick) / 1000);
          if (seconds > 0) send({ event: "visible", ...dataFor(state), seconds });
        }
        cards.delete(element);
      }
    }
    inlineVideos();
  }

  function inlineVideos() {
    for (const video of document.querySelectorAll("video")) {
      video.playsInline = true;
      video.setAttribute("playsinline", "");
      video.setAttribute("webkit-playsinline", "");
      if (videos.has(video)) continue;
      videos.add(video);
      video.addEventListener("timeupdate", () => {
        const previous = videoTimes.get(video);
        const current = video.currentTime;
        videoTimes.set(video, current);
        if (!window.__feedWindowEnabled) return;
        if (!Number.isFinite(previous) || !Number.isFinite(current) ||
            current <= previous || current - previous > 1.5 ||
            video.paused || document.visibilityState !== "visible") return;
        const state = stateFor(video);
        if (!state || !state.announced || !visible(state.element)) return;
        for (let second = Math.floor(previous); second <= Math.floor(current); second++) {
          if (second >= 0 && !state.buckets.has(second)) {
            state.buckets.add(second);
            state.unsentBuckets.add(second);
          }
        }
      });
    }
  }

  function stateFor(element) {
    let node = element;
    while (node) {
      if (cards.has(node)) return cards.get(node);
      node = node.parentElement;
    }
    // Instagram sometimes moves controls into a dialog outside the post card.
    if (/^\/(p|reel)\//.test(location.pathname)) {
      const direct = [...cards.values()].find(state =>
        state.permalink?.replace(/\/$/, "") === location.pathname.replace(/\/$/, ""));
      if (direct) return direct;
    }
    if (commentContext && Date.now() - commentContext.at < 10 * 60 * 1000 &&
        element.closest?.("[role='dialog'], dialog, form")) {
      const opened = [...cards.values()].find(state =>
        state.observationId === commentContext.observationId && state.element.isConnected);
      if (opened) return opened;
    }
    const active = [...cards.values()].filter(state => state.announced && visible(state.element));
    return active.length === 1 ? active[0] : null;
  }

  function tick() {
    const now = Date.now();
    scan();
    if (!window.__feedWindowEnabled) {
      for (const state of cards.values()) {
        state.since = null;
        state.lastTick = null;
        state.unsentBuckets.clear();
      }
      if (now - lastStatus > 4000) {
        send({ event: "status", enabled: false, candidates: cards.size, visible: 0,
               surface: surface() || "Other page" });
        lastStatus = now;
      }
      return;
    }
    let onScreen = 0;
    for (const state of cards.values()) {
      if (!visible(state.element)) {
        if (state.announced && state.lastTick != null && state.since != null) {
          const seconds = Math.min(3, (now - state.lastTick) / 1000);
          if (seconds > 0 && seconds <= 3) send({ event: "visible", ...dataFor(state), seconds });
        }
        state.since = null;
        state.lastTick = null;
        continue;
      }
      onScreen++;
      if (state.since == null) state.since = now;
      if (state.announced && state.lastTick == null) state.lastTick = now;
      if (!state.announced && now - state.since >= 700) {
        send({ event: "impression", ...dataFor(state, true) });
        state.announced = true;
        state.lastTick = now;
      }
      if (!state.announced) continue;
      if (state.lastTick != null && now - state.lastTick >= 1000) {
        const seconds = Math.min(3, (now - state.lastTick) / 1000);
        send({ event: "visible", ...dataFor(state), seconds });
        state.lastTick = now;
      }
      const video = state.element.querySelector("video");
      const duration = video?.duration;
      if (state.unsentBuckets.size) {
        const watch = { event: "watch", ...dataFor(state), buckets: [...state.unsentBuckets] };
        if (Number.isFinite(duration) && duration > 0) watch.duration = duration;
        send(watch);
        state.unsentBuckets.clear();
      }
    }
    if (now - lastStatus > 4000) {
      send({ event: "status", enabled: true, candidates: cards.size, visible: onScreen,
             surface: surface() || "Other page" });
      lastStatus = now;
    }
  }

  function safeTick() {
    try { tick(); }
    catch (error) {
      send({ event: "status", enabled: false, candidates: cards.size, visible: 0,
        surface: surface() || "Other page",
        error: String(error?.message || "The page observer stopped").slice(0, 160) });
    }
  }

  window.__instagramCaptureSetEnabled = enabled => {
    const wasEnabled = window.__feedWindowEnabled;
    window.__feedWindowEnabled = !!enabled;
    if (wasEnabled !== window.__feedWindowEnabled) lastStatus = 0;
    safeTick();
    return window.__feedWindowEnabled;
  };

  function interaction(event, element, details = {}) {
    if (!window.__feedWindowEnabled) return;
    const state = stateFor(element);
    if (!state || !state.announced) return;
    const key = state.observationId + ":" + event +
      (event === "comment_submit" ? ":" + (details.commentText || "") : "");
    const now = Date.now();
    const previous = recentActions.get(key);
    if (previous != null && now - previous < 1400) return;
    recentActions.set(key, now);
    if (recentActions.size > 500) {
      for (const [oldKey, at] of recentActions) {
        if (now - at > 1500) recentActions.delete(oldKey);
      }
    }
    if (event === "comments_open") {
      commentContext = { observationId: state.observationId, at: now };
    }
    send({ event: "interaction", action: event, ...dataFor(state), ...details });
  }

  function actionName(element) {
    const control = element.closest?.("button, [role='button'], a, [role='link']") || element;
    const svg = control.querySelector?.("svg[aria-label], [title]");
    const text = [
      control.getAttribute?.("aria-label"), svg?.getAttribute("aria-label"),
      svg?.getAttribute("title"), control.innerText
    ].filter(Boolean).join(" ").trim().slice(0, 100);
    if (/^(unlike|remove like|gefällt mir nicht)\b/i.test(text)) return "unlike";
    if (/^(like|gefällt mir|j'aime|me gusta)\b/i.test(text) &&
        !/^(unlike|remove like)\b/i.test(text)) return "like";
    if (/^(unsave|remove from saved|remove from collection)\b/i.test(text)) return "unsave";
    if (/^(save|bookmark|speichern|guardar|enregistrer)\b/i.test(text)) return "save";
    if (/\b(comment|comments|kommentar|commentaire|comentario|replies|antworten|respuestas)\b/i.test(text) &&
        !/\b(add|post|submit|send|hinzufügen)\b/i.test(text)) return "comments_open";
    if (/^(follow|folgen|suivre|seguir)\b/i.test(text) &&
        !/^(following|gefolgt|followed)\b/i.test(text)) return "follow";
    return null;
  }

  document.addEventListener("click", event => {
    const target = event.target;
    if (!target?.closest) return;
    const mediaLink = target.closest("a[href]");
    const linkedVideo = mediaLink && postPath.test(pathOf(mediaLink))
      ? mediaLink.querySelector("video") : null;
    const control = target.closest("button, [role='button']");
    let tappedVideo = target.tagName === "VIDEO" ? target : linkedVideo;
    // Some media overlays are siblings of the video rather than inside its link.
    const playbackControl = /^(play|pause)$/i.test(
      (control?.getAttribute?.("aria-label") || control?.innerText || "").trim());
    if (!tappedVideo && (!control || playbackControl) && !mediaLink &&
        Number.isFinite(event.clientX) && Number.isFinite(event.clientY)) {
      const video = target.closest("article, [role='article']")?.querySelector("video");
      const rect = video?.getBoundingClientRect();
      if (rect && event.clientX >= rect.left && event.clientX <= rect.right &&
          event.clientY >= rect.top && event.clientY <= rect.bottom) tappedVideo = video;
    }
    if (tappedVideo && (!control || playbackControl) && surface()) {
      // Tapping the media itself controls playback without opening a larger player.
      event.preventDefault();
      event.stopImmediatePropagation();
      interaction("media_click", tappedVideo);
      if (tappedVideo.paused) { interaction("play", tappedVideo); tappedVideo.play()?.catch?.(() => {}); }
      else { interaction("pause", tappedVideo); tappedVideo.pause(); }
      return;
    }
    const action = actionName(target);
    if (!action) {
      const media = target.closest("img, video");
      const box = media?.getBoundingClientRect?.();
      if (media && box?.width >= 160 && box?.height >= 160) {
        interaction("media_click", media);
      } else if (mediaLink && postPath.test(pathOf(mediaLink))) {
        interaction("media_click", mediaLink);
      }
      return;
    }
    interaction(action, target);
    if (action === "follow") {
      const button = target.closest("button, [role='button']");
      setTimeout(() => {
        if (button && /^(following|gefolgt|abonniert|siguiendo)$/i.test(button.innerText.trim())) {
          const state = stateFor(button);
          if (state) send({ event: "relationship", ...dataFor(state, true), relationship: "Followed" });
        }
      }, 700);
    }
  }, true);

  function isCommentField(element) {
    if (!element?.matches?.("input, textarea, [contenteditable='true'], [contenteditable='plaintext-only'], [role='textbox']")) return false;
    if (element.getAttribute("type") === "password") return false;
    const hint = [element.getAttribute("placeholder"), element.getAttribute("aria-label"),
      element.getAttribute("aria-placeholder"), element.getAttribute("data-placeholder")]
      .filter(Boolean).join(" ");
    if (/comment|kommentar|commentaire|comentario/i.test(hint)) return true;
    // Instagram sometimes puts an unlabelled contenteditable in a comments dialog.
    return !!(commentContext && Date.now() - commentContext.at < 10 * 60 * 1000 &&
      element.closest?.("[role='dialog'], dialog") &&
      element.matches("[contenteditable='true'], [contenteditable='plaintext-only'], [role='textbox']"));
  }
  function commentFieldNear(element) {
    const fields = "input, textarea, [contenteditable='true'], [contenteditable='plaintext-only'], [role='textbox']";
    for (const parent of [element?.closest?.("form"),
      element?.closest?.("article, [role='article'], [role='dialog']"),
      element?.parentElement]) {
      const field = [...(parent?.querySelectorAll?.(fields) || [])].find(isCommentField);
      if (field) return field;
    }
    return isCommentField(document.activeElement) ? document.activeElement : null;
  }
  function submitComment(field) {
    const value = ("value" in field ? field.value : field.innerText || "").trim();
    if (value) interaction("comment_submit", field, { commentText: value.slice(0, 10000) });
  }
  document.addEventListener("focusin", event => {
    if (!isCommentField(event.target)) return;
    const state = stateFor(event.target);
    if (state) commentContext = { observationId: state.observationId, at: Date.now() };
  }, true);
  document.addEventListener("submit", event => {
    const field = commentFieldNear(event.target);
    if (isCommentField(field)) submitComment(field);
  }, true);
  document.addEventListener("keydown", event => {
    if (event.key === "Enter" && !event.shiftKey && isCommentField(event.target)) {
      submitComment(event.target);
    }
  }, true);
  document.addEventListener("click", event => {
    const target = event.target;
    const control = target?.closest?.("button, [role='button']");
    const label = (control?.getAttribute?.("aria-label") || control?.innerText || "").trim();
    if (!/^(post|send|publish|submit|share|veröffentlichen|publicar|publier)\b/i.test(label)) return;
    const field = commentFieldNear(control);
    if (isCommentField(field)) submitComment(field);
  }, true);

  let touchStart = null;
  document.addEventListener("touchstart", event => {
    const touch = event.changedTouches?.[0];
    if (!touch) return;
    touchStart = { x: touch.clientX, y: touch.clientY, target: event.target };
  }, { passive: true, capture: true });
  document.addEventListener("touchend", event => {
    const touch = event.changedTouches?.[0];
    if (!touch || !touchStart) return;
    const dx = touch.clientX - touchStart.x, dy = touch.clientY - touchStart.y;
    if (Math.abs(dx) >= 55 && Math.abs(dx) > Math.abs(dy) * 1.25) {
      interaction("swipe", touchStart.target, { direction: dx > 0 ? "right" : "left" });
    } else if (Math.abs(dy) >= 55 && Math.abs(dy) > Math.abs(dx) * 1.25) {
      interaction("swipe", touchStart.target, { direction: dy > 0 ? "down" : "up" });
    }
    touchStart = null;
  }, { passive: true, capture: true });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") safeTick();
  });
  setInterval(safeTick, 1000);
  safeTick();
})();
