/* Page-world observer: reads selected public feed metadata from responses
   Instagram already delivered to its own page. Never changes a response and
   never sends raw JSON, credentials, cookies, headers, or media to native code. */
(() => {
  if (!["instagram.com", "www.instagram.com"].includes(location.hostname)) return;
  if (window.__feedWindowMetadataV7) return;
  window.__feedWindowMetadataV7 = true;
  const postPath = /^[A-Za-z0-9_-]{1,64}$/;
  const lastDiagnostic = new Map();
  function diagnostic(code) {
    const now = Date.now();
    if (lastDiagnostic.has(code) && now - lastDiagnostic.get(code) < 10000) return;
    lastDiagnostic.set(code, now);
    // Fixed codes only: never send response bodies, URLs or exception messages.
    try { window.webkit.messageHandlers.feedMetadata.postMessage({
      event: "metadata_diagnostic", code
    }); } catch (_) {}
  }
  diagnostic("reader_ready");

  function postLink(raw) {
    try {
      const url = new URL(raw, location.href);
      const match = /^\/(p|reel)\/([A-Za-z0-9_-]{1,64})\/?$/.exec(url.pathname);
      return ["instagram.com", "www.instagram.com"].includes(url.hostname) && match
        ? { link: `https://www.instagram.com/${match[1]}/${match[2]}/`, code: match[2] }
        : null;
    } catch (_) { return null; }
  }

  function codeOf(media, node) {
    const value = media.code || media.shortcode || media.short_code ||
      node.code || node.shortcode || node.short_code;
    if (typeof value === "string" && postPath.test(value)) return value;
    return postLink(media.permalink || node.permalink)?.code || null;
  }

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

  function mediaKeys(media) {
    const keys = new Set();
    function add(raw) {
      for (const key of assetKeys(raw)) {
        if (keys.size < 24) keys.add(key);
      }
    }
    for (const value of [media.id, media.pk, media.media_id]) {
      const match = /^(\d{8,20})(?:_\d{1,20})?$/.exec(String(value || ""));
      if (match) keys.add("i_" + match[1]);
    }
    const imageCandidates = Array.isArray(media.image_versions2?.candidates)
      ? media.image_versions2.candidates : [];
    const videoCandidates = Array.isArray(media.video_versions) ? media.video_versions : [];
    const carousel = Array.isArray(media.carousel_media) ? media.carousel_media : [];
    const displayResources = Array.isArray(media.display_resources) ? media.display_resources : [];
    for (const value of [media.display_url, media.thumbnail_src, media.thumbnail_url,
                         media.image_url, media.video_url]) add(value);
    for (const candidate of imageCandidates.slice(0, 8)) {
      add(candidate.url);
    }
    for (const candidate of videoCandidates.slice(0, 5)) add(candidate.url);
    for (const resource of displayResources.slice(0, 8)) add(resource.src);
    for (const child of carousel.slice(0, 5)) {
      const childCandidates = Array.isArray(child.image_versions2?.candidates)
        ? child.image_versions2.candidates : [];
      for (const candidate of childCandidates.slice(0, 3)) {
        add(candidate.url);
      }
    }
    return [...keys];
  }

  function captionOf(media, node) {
    const candidates = [media.caption, node.caption,
      media.edge_media_to_caption?.edges?.[0]?.node?.text,
      node.edge_media_to_caption?.edges?.[0]?.node?.text];
    for (const candidate of candidates) {
      const value = Array.isArray(candidate) ? candidate[0] : candidate;
      const text = typeof value === "string" ? value : value?.text;
      if (typeof text === "string" && text.trim()) return text.trim().slice(0, 5000);
    }
    return "";
  }

  function hashtagsOf(caption) {
    return [...new Set(caption.match(/#[\p{L}\p{N}_]{1,100}/gu) || [])].slice(0, 100);
  }

  function interesting(url) {
    try {
      const parsed = new URL(url, location.href);
      return (parsed.hostname === "instagram.com" || parsed.hostname.endsWith(".instagram.com")) &&
        (/\/graphql\b|\/feed\/|\/clips\/|\/discover\/|\/media\/\d+\/info\b/.test(parsed.pathname));
    } catch (_) { return false; }
  }

  function emitNode(node, surface, suggestedHint = false) {
    if (!node || typeof node !== "object") return;
    const media = node.media_or_ad || node.media || node.explore_story || node;
    if (!media || typeof media !== "object") return;
    const code = codeOf(media, node);
    if (!code) return;
    const isVideo = Boolean(media.video_versions || media.video_url ||
      media.media_type === 2 || media.is_video || surface === "Reels");
    const kind = media.product_type === "clips" || media.clips_metadata ||
      surface === "Reels" ? "reel" : "p";
    const user = [media.user, media.owner, node.user, node.owner]
      .find(candidate => typeof candidate?.username === "string" && candidate.username) ||
      media.user || media.owner || node.user || node.owner || {};
    const status = user.friendship_status || {};
    let relationship = "Unknown";
    if (status.following === true || status.is_following === true) relationship = "Followed";
    else if (status.following === false || status.is_following === false) {
      relationship = "Not followed";
    }
    const suggested = Boolean(suggestedHint || node.explore_story || node.suggested_post ||
      node.is_suggested || media.is_suggested);
    if (suggested && relationship !== "Followed") relationship = "Suggested";
    const sponsored = Boolean(node.ad || node.is_ad || media.is_ad || media.ad_id);
    const caption = captionOf(media, node);
    const directLink = postLink(media.permalink || node.permalink);
    const payload = {
      event: "metadata",
      permalink: directLink?.code === code ? directLink.link :
        `https://www.instagram.com/${kind}/${code}/`,
      account: typeof user.username === "string" ? user.username.slice(0, 30) : "",
      relationship,
      label: sponsored ? "Sponsored" : suggested ? "Suggested" : "Post",
      isVideo,
      surface,
      mediaKeys: mediaKeys(media)
    };
    if (caption) {
      payload.caption = caption;
      payload.hashtags = hashtagsOf(caption);
    }
    if (Number.isFinite(media.video_duration) && media.video_duration > 0) {
      payload.videoDuration = Math.min(media.video_duration, 36000);
    }
    try { window.webkit.messageHandlers.feedMetadata.postMessage(payload); } catch (_) {}
  }

  // Find media in ordinary, suggested, and preloaded feed response shapes.
  function inspect(json) {
    let budget = 30_000;
    const seenCodes = new Set();
    function walk(value, depth, surface, suggested) {
      if (!value || typeof value !== "object" || depth > 22 || --budget <= 0) return;
      if (Array.isArray(value)) {
        for (const item of value.slice(0, 250)) walk(item, depth + 1, surface, suggested);
        return;
      }
      const node = value.media_or_ad || value.media || value.explore_story || value;
      const code = codeOf(node, value);
      const hasMedia = node?.image_versions2 || node?.display_resources ||
        node?.video_versions || node?.display_url ||
        node?.video_url || node?.carousel_media ||
        (node?.media_type === 2 && node?.video_duration);
      if (typeof code === "string" && postPath.test(code) && hasMedia &&
          !seenCodes.has(code)) {
        seenCodes.add(code);
        emitNode(value, surface, suggested);
      }
      for (const [key, child] of Object.entries(value)) {
        if (["image_versions2", "video_versions", "carousel_media", "caption",
             "comments", "likers"].includes(key)) continue;
        const childSurface = /clips__home__connection|reels?(?:_|__home__connection)/i.test(key)
          ? "Reels" : /feed__|feed_items|timeline/i.test(key) ? "Home" : surface;
        walk(child, depth + 1, childSurface,
             suggested || /suggest|recommend/i.test(key));
      }
    }
    walk(json, 0, "Home", false);
    if (budget <= 0) diagnostic("scan_limit");
  }

  function inspectWhenIdle(input) {
    const task = () => {
      try { inspect(typeof input === "function" ? input() : input); }
      catch (_) { diagnostic("parse_or_scan_failed"); }
    };
    if (typeof requestIdleCallback === "function") {
      requestIdleCallback(task, { timeout: 1800 });
    } else {
      setTimeout(task, 0);
    }
  }

  // The first feed is frequently embedded in the HTML, before fetch/XHR hooks run.
  function scanPreloadedFeed() {
    for (const script of document.querySelectorAll(
      "script[data-sjs], script[type='application/json']")) {
      if (script.__feedWindowScanned) continue;
      script.__feedWindowScanned = true;
      const source = script.textContent || "";
      if (source.length > 8_000_000 ||
          !/xdt_api__v1__|media_or_ad|image_versions2/.test(source)) {
        continue;
      }
      inspectWhenIdle(() => JSON.parse(source));
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => setTimeout(scanPreloadedFeed, 300),
      { once: true });
  } else {
    setTimeout(scanPreloadedFeed, 0);
  }
  setTimeout(scanPreloadedFeed, 2500);

  const originalFetch = window.fetch;
  if (typeof originalFetch === "function") {
    window.fetch = function(...args) {
      const result = originalFetch.apply(this, args);
      const url = typeof args[0] === "string" ? args[0] : args[0]?.url;
      if (interesting(url)) {
        result.then(response => response.clone().json().then(inspectWhenIdle)
          .catch(() => diagnostic("response_parse_failed")))
          .catch(() => {});
      }
      return result;
    };
  }

  const originalOpen = XMLHttpRequest.prototype.open;
  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    this.__feedWindowURL = url;
    return originalOpen.call(this, method, url, ...rest);
  };
  XMLHttpRequest.prototype.send = function(...args) {
    if (interesting(this.__feedWindowURL)) {
      this.addEventListener("loadend", () => {
        try {
          const value = this.responseType === "json" ? this.response : JSON.parse(this.responseText);
          inspectWhenIdle(value);
        } catch (_) { diagnostic("response_parse_failed"); }
      }, { once: true });
    }
    return originalSend.apply(this, args);
  };
})();
