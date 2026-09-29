const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const observerSource = fs.readFileSync(path.join(__dirname, '../InstagramDonation/FeedObserver.js'), 'utf8');
const metadataSource = fs.readFileSync(path.join(__dirname, '../InstagramDonation/FeedMetadata.js'), 'utf8');

function scenario({ route = '/', href = '/p/example_123/', visible = true,
                    video = false, photo = false, heading = 'city_archive', articleInDOM = true,
                    accountHref = '/city_archive/', autoEnable = true } = {}) {
  let now = 0;
  let currentHref = href;
  const messages = [];
  const listeners = new Map();
  const intervals = [];
  const timeouts = [];
  const link = {
    tagName: 'A', getAttribute: name => name === 'href' ? currentHref : null,
    querySelectorAll: () => [], matches: selector => selector === 'a[href]',
    closest: () => article
  };
  const accountLink = { getAttribute: () => accountHref };
  const followButton = {
    tagName: 'BUTTON', innerText: 'Following',
    getAttribute: () => null, querySelector: () => null,
    closest: () => followButton
  };
  const saveButton = {
    tagName: 'BUTTON', innerText: '',
    getAttribute: name => name === 'aria-label' ? 'Save' : null,
    querySelector: () => null,
    closest: selector => selector.includes('button') ? saveButton : null
  };
  const header = {
    innerText: heading,
    querySelectorAll: selector => selector === 'a[href]' ? [accountLink] : [followButton]
  };
  const movie = {
    tagName: 'VIDEO', paused: true, currentTime: 0, duration: 10,
    poster: 'https://scontent.cdninstagram.com/v/t51.2885-15/1234567890123_s720x720_n.jpg?size=large',
    parentElement: null, handlers: {},
    getBoundingClientRect: () => ({ left: 0, right: 350, top: 100, bottom: 430,
      width: 350, height: 330 }),
    addEventListener(type, fn) { this.handlers[type] = fn; },
    setAttribute(name) { this[name] = true; },
    play() { this.paused = false; return Promise.resolve(); },
    pause() { this.paused = true; }
  };
  const photoMedia = {
    tagName: 'IMG', complete: true, naturalWidth: 720,
    currentSrc: 'https://scontent.cdninstagram.com/v/t51.2885-15/2345678901234_n.jpg',
    parentElement: null,
    getBoundingClientRect: () => ({ left: 0, right: 350, top: 100, bottom: 430,
      width: 350, height: 330 })
  };
  const article = {
    tagName: 'ARTICLE', isConnected: true, innerText: heading,
    getBoundingClientRect: () => ({ top: visible ? 80 : 900,
      bottom: visible ? 490 : 1310, left: 0, right: 350, width: 350, height: 410 }),
    querySelectorAll(selector) {
      if (selector === 'a[href]') return [link];
      if (selector === "button, [role='button']") return [followButton, likeButton, saveButton];
      if (selector === 'video' || selector === 'video, img' || selector === 'img, video') {
        return video ? [movie] : photo ? [photoMedia] : [];
      }
      return [];
    },
    querySelector(selector) {
      if (selector === 'header') return header;
      if (selector === 'video') return video ? movie : null;
      if (selector === 'video, img') return video ? movie : photo ? photoMedia : null;
      return null;
    },
    matches: selector => selector.includes('article')
  };
  link.parentElement = article;
  followButton.parentElement = article;
  saveButton.parentElement = article;
  movie.parentElement = article;
  photoMedia.parentElement = article;
  const likeButton = {
    tagName: 'BUTTON', parentElement: article, innerText: '',
    getAttribute: name => name === 'aria-label' ? 'Like' : null,
    querySelector: () => null,
    closest: selector => selector.includes('button') ? likeButton : null
  };
  const document = {
    visibilityState: 'visible', documentElement: {},
    querySelectorAll(selector) {
      if (selector === 'main article, article, [role=\'article\']') {
        return articleInDOM ? [article] : [];
      }
      if (selector === 'main a[href], [role=\'main\'] a[href]') return [link];
      if (selector === "main video, main img, [role='main'] video, [role='main'] img") {
        return video ? [movie] : photo ? [photoMedia] : [];
      }
      if (selector === 'video') return video ? [movie] : [];
      return [];
    },
    querySelector: () => article,
    addEventListener(type, fn) { listeners.set(type, [...(listeners.get(type) || []), fn]); }
  };
  const location = { hostname: 'www.instagram.com', pathname: route,
    href: 'https://www.instagram.com' + route };
  class Clock extends Date { static now() { return now; } }
  const window = { webkit: { messageHandlers: { donation: {
    postMessage(data) { messages.push(JSON.parse(JSON.stringify(data))); }
  } } } };
  const context = { window, document, location, URL, Date: Clock, innerWidth: 350, innerHeight: 700,
    setInterval: fn => intervals.push(fn),
    setTimeout: fn => { timeouts.push(fn); return timeouts.length; } };
  vm.runInNewContext(observerSource, context);
  if (autoEnable) window.__feedWindowEnabled = true;
  return {
    messages, movie, photoMedia, likeButton, saveButton, followButton, article, header,
    accountLink, document, window,
    setHref(value) { currentHref = value; },
    setAccountHref(value) { accountHref = value; },
    step(ms) { now += ms; intervals.forEach(fn => fn()); },
    click(target, x, y) {
      const event = { target, clientX: x, clientY: y,
        prevented: false, preventDefault() { this.prevented = true; },
        stopImmediatePropagation() {} };
      for (const handler of listeners.get('click') || []) handler(event);
      return event;
    },
    dispatch(type, event) { for (const handler of listeners.get(type) || []) handler(event); },
    finishTimeouts() { timeouts.splice(0).forEach(fn => fn()); }
  };
}

const startup = scenario({ video: true, autoEnable: false });
startup.step(5000);
assert(startup.messages.some(x => x.event === 'status' && x.enabled === false));
startup.window.__instagramCaptureSetEnabled(true);
assert(startup.messages.some(x => x.event === 'status' && x.enabled === true),
  'enabling recording must immediately confirm the page recorder is running');
startup.step(1000);
assert(startup.messages.some(x => x.event === 'impression'),
  'the first visible post must be counted after startup enable');

const broken = scenario({ video: true });
broken.article.querySelectorAll = () => { throw new Error('card scan failed'); };
broken.step(1000);
assert(broken.messages.some(x => x.event === 'status' && x.error === 'card scan failed'),
  'a page scan error must be reported instead of silently stopping the recorder');

const normal = scenario({ video: true });
normal.step(1000);
normal.step(1000);
assert.equal(normal.messages.filter(x => x.event === 'impression').length, 1);
assert(!normal.messages.some(x => x.event === 'capture'), 'the recorder must not request images');
normal.step(1000);
assert(normal.messages.some(x => x.event === 'visible' && x.seconds > 0));
normal.movie.paused = false;
normal.movie.currentTime = 0.2;
normal.movie.handlers.timeupdate();
normal.movie.currentTime = 1.2;
normal.movie.handlers.timeupdate();
normal.step(1000);
assert(normal.messages.some(x => x.event === 'watch' && x.buckets.length >= 1));
normal.click(normal.likeButton);
assert(normal.messages.some(x => x.event === 'interaction' && x.action === 'like'));
normal.click(normal.saveButton);
assert(normal.messages.some(x => x.event === 'interaction' && x.action === 'save'));
const overlay = { closest: selector => selector.includes('article') ? normal.article : null };
normal.movie.paused = true;
assert(normal.click(overlay, 120, 200).prevented, 'tapping a video overlay stays inline');
assert.equal(normal.movie.paused, false);
assert.equal(normal.messages.find(x => x.event === 'impression').relationship, 'Followed');
normal.followButton.innerText = 'Follow';
normal.click(normal.followButton);
assert(normal.messages.some(x => x.event === 'interaction' && x.action === 'follow'));
normal.followButton.innerText = 'Following';
normal.finishTimeouts();
assert(normal.messages.some(x => x.event === 'relationship' && x.relationship === 'Followed'));
const commentField = {
  parentElement: normal.article, value: 'A comment for this post',
  matches: selector => selector.includes('input'),
  getAttribute: name => name === 'placeholder' ? 'Add a comment' : null
};
normal.dispatch('keydown', { key: 'Enter', shiftKey: false, target: commentField });
assert(normal.messages.some(x => x.event === 'interaction' && x.action === 'comment_submit'));
assert(normal.messages.some(x => x.event === 'interaction' &&
  x.action === 'comment_submit' && x.commentText === 'A comment for this post'));
assert(!normal.messages.some(x => x.commentText && x.action !== 'comment_submit'));
const postButton = {
  tagName: 'BUTTON', innerText: 'Post', parentElement: normal.article,
  getAttribute: () => null, querySelector: () => null,
  closest: selector => selector.includes('button') ? postButton : null
};
normal.document.activeElement = commentField;
normal.step(1500);
commentField.value = 'Submitted by pressing Post';
normal.click(postButton);
assert(normal.messages.some(x => x.action === 'comment_submit' &&
  x.commentText === 'Submitted by pressing Post'));
const commentsButton = {
  parentElement: normal.article, innerText: 'View all 12 comments',
  getAttribute: () => null, querySelector: () => null,
  closest: selector => selector.includes('button') ? commentsButton : null
};
normal.click(commentsButton);
assert(normal.messages.some(x => x.action === 'comments_open'),
  'opening a comments list is tied to the post');
const dialog = { parentElement: null, querySelectorAll: () => [portalField] };
const portalField = {
  parentElement: dialog, innerText: 'A comment in the dialog',
  getAttribute: () => null,
  matches: selector => selector.includes('contenteditable') || selector.includes('textbox'),
  closest: selector => selector.includes('dialog') ? dialog : null
};
const dialogPost = {
  parentElement: dialog, innerText: 'Post',
  getAttribute: () => null, querySelector: () => null,
  closest: selector => selector.includes('button') ? dialogPost :
    selector.includes('dialog') ? dialog : null
};
normal.document.activeElement = portalField;
normal.click(dialogPost);
assert(normal.messages.some(x => x.action === 'comment_submit' &&
  x.commentText === 'A comment in the dialog'),
  'an unlabelled comment box in a detached dialog is tied to the opened post');
normal.dispatch('touchstart', { target: normal.movie,
  changedTouches: [{ clientX: 240, clientY: 200 }] });
normal.dispatch('touchend', { target: normal.movie,
  changedTouches: [{ clientX: 120, clientY: 205 }] });
assert(normal.messages.some(x => x.event === 'interaction' &&
  x.action === 'swipe' && x.direction === 'left'));
normal.step(1500);
normal.dispatch('touchstart', { target: normal.movie,
  changedTouches: [{ clientX: 170, clientY: 310 }] });
normal.dispatch('touchend', { target: normal.movie,
  changedTouches: [{ clientX: 173, clientY: 185 }] });
assert(normal.messages.some(x => x.action === 'swipe' && x.direction === 'up'));
assert(normal.movie.playsinline, 'videos are configured for inline playback');
assert(!normal.messages.some(x => 'password' in x || 'cookie' in x));
normal.window.__feedWindowEnabled = false;
const beforePause = normal.messages.filter(x => x.event === 'visible').length;
const interactionsBeforePause = normal.messages.filter(x => x.event === 'interaction').length;
normal.step(3000);
normal.click(normal.likeButton);
assert.equal(normal.messages.filter(x => x.event === 'visible').length, beforePause,
  'pausing must stop collecting visible time');
assert.equal(normal.messages.filter(x => x.event === 'interaction').length, interactionsBeforePause,
  'pausing must stop collecting interactions');
normal.window.__instagramCaptureSetEnabled(true);
normal.step(1000);
assert(normal.messages.filter(x => x.event === 'visible').length > beforePause,
  'resume after viewing results must collect visible time again');

const photo = scenario({ video: false, photo: true });
photo.step(1000); photo.step(1000);
assert(photo.messages.some(x => x.event === 'impression'));
assert(!photo.messages.some(x => x.event === 'capture'));

const lateAccount = scenario({ video: true, heading: 'Suggested for you', accountHref: null });
lateAccount.step(1000); lateAccount.step(1000);
assert.equal(lateAccount.messages.find(x => x.event === 'impression').account, '');
lateAccount.setAccountHref('/bistro_notes/');
lateAccount.step(1000);
assert(lateAccount.messages.some(x => x.event === 'relationship' &&
  x.account === 'bistro_notes'), 'a late author link must update an already saved result');

const lateLink = scenario({ href: null, photo: true });
lateLink.step(1000); lateLink.step(1000);
const originalLateQuery = lateLink.article.querySelectorAll.bind(lateLink.article);
lateLink.article.querySelectorAll = selector => selector.includes('data-permalink')
  ? [{ getAttribute: key => key === 'data-permalink' ? '/p/late_123/' : null }]
  : originalLateQuery(selector);
lateLink.step(1000);
assert(lateLink.messages.some(x => x.event === 'relationship' &&
  x.permalink === 'https://www.instagram.com/p/late_123/'),
  'a post URL exposed later in a data attribute must update its result');

// Reproduces the reported mobile Home layout: a visible video card with no post link.
const linkless = scenario({ href: null, video: true });
linkless.step(1000);
linkless.step(1000);
const unidentified = linkless.messages.find(x => x.event === 'impression');
assert(unidentified, 'a feed card without a permalink must still be recorded: ' +
  JSON.stringify(linkless.messages));
assert.equal(unidentified.permalink, '');
assert.match(unidentified.observationId, /^[0-9a-f-]{36}$/i);
assert(unidentified.mediaKeys.includes('m_1234567890123'));
linkless.step(4000);
assert(linkless.messages.some(x => x.event === 'status' && x.candidates === 1 &&
  x.enabled === true));
linkless.click(linkless.likeButton);
assert(linkless.messages.some(x => x.event === 'interaction' &&
  x.observationId === unidentified.observationId && x.action === 'like'));
linkless.movie.paused = false;
linkless.movie.currentTime = 0.2;
linkless.movie.handlers.timeupdate();
linkless.movie.currentTime = 1.1;
linkless.movie.handlers.timeupdate();
linkless.movie.currentSrc = 'https://video.cdninstagram.com/v/t50.2886-16/1234567890123_v.mp4';
linkless.step(1000);
assert(linkless.messages.some(x => x.event === 'watch' &&
  x.observationId === unidentified.observationId));
assert.equal(linkless.messages.filter(x => x.event === 'impression').length, 1,
  'starting a video must not split one card into multiple records');

const recycled = scenario({ href: null, video: true });
for (let index = 0; index < 70; index++) {
  recycled.movie.poster = 'https://scontent.cdninstagram.com/v/t51.2885-15/' +
    (1234567890123 + index) + '_n.jpg';
  recycled.step(1000);
  recycled.step(1000);
}
const manyPosts = recycled.messages.filter(x => x.event === 'impression');
assert.equal(manyPosts.length, 70, 'a recycled feed card must continue counting past 64 posts');
assert.equal(new Set(manyPosts.map(x => x.observationId)).size, 70);

const linked = scenario({ video: true });
linked.step(1000); linked.step(1000);
linked.movie.poster = 'https://scontent.cdninstagram.com/v/t51.2885-15/7777777777777_n.jpg';
linked.step(1000); linked.step(1000);
assert.equal(linked.messages.filter(x => x.event === 'impression').length, 1,
  'a changing image on the same linked post must not create a new post');

const lostLink = scenario({ video: true });
lostLink.step(1000); lostLink.step(1000);
lostLink.setHref(null);
lostLink.movie.poster = 'https://scontent.cdninstagram.com/v/t51.2885-15/8888888888888_n.jpg';
lostLink.step(1000); lostLink.step(1000);
const withoutOldLink = lostLink.messages.filter(x => x.event === 'impression');
assert.equal(withoutOldLink.length, 2);
assert.equal(withoutOldLink[1].permalink, '',
  'a reused card without a link must not inherit the previous post link');

const unstructured = scenario({ href: null, video: true, articleInDOM: false });
unstructured.step(1000);
unstructured.step(1000);
assert(unstructured.messages.some(x => x.event === 'impression' && x.permalink === ''),
  'a media card without an article or post link must still be observed');

const attributed = scenario({ href: null, photo: true });
const originalQuery = attributed.article.querySelectorAll.bind(attributed.article);
attributed.article.querySelectorAll = selector =>
  selector.includes('data-shortcode') ? [{ getAttribute: name =>
    name === 'data-shortcode' ? 'fallback_123' : null }] : originalQuery(selector);
attributed.step(1000);
attributed.step(1000);
assert(attributed.messages.some(x => x.event === 'impression' &&
  x.permalink === 'https://www.instagram.com/p/fallback_123/'),
  'a shortcode attribute can recover a link when there is no anchor: ' +
  JSON.stringify(attributed.messages));

const named = scenario({ href: null, photo: true, accountHref: null, heading: 'Suggested for you' });
const namedQuery = named.article.querySelectorAll.bind(named.article);
named.article.querySelectorAll = selector => selector.includes('data-username')
  ? [{ getAttribute: key => key === 'data-username' ? 'vienna_food_blog' : null }]
  : namedQuery(selector);
named.step(1000); named.step(1000);
assert(named.messages.some(x => x.event === 'impression' && x.account === 'vienna_food_blog'),
  'an author attribute can recover the account name');

const ambiguous = scenario({ href: null, photo: true });
const ambiguousQuery = ambiguous.article.querySelectorAll.bind(ambiguous.article);
ambiguous.article.querySelectorAll = selector => selector === 'a[href]'
  ? [{ getAttribute: () => '/p/first_123/' }, { getAttribute: () => '/p/second_456/' }]
  : ambiguousQuery(selector);
ambiguous.step(1000); ambiguous.step(1000);
assert.equal(ambiguous.messages.find(x => x.event === 'impression').permalink, '',
  'two possible post links must not be assigned at random');

const mediaLinked = scenario({ href: null, photo: true });
const mediaQuery = mediaLinked.article.querySelectorAll.bind(mediaLinked.article);
mediaLinked.article.querySelectorAll = selector => selector === 'a[href]'
  ? [{ getAttribute: () => '/p/media_123/' }, { getAttribute: () => '/p/other_456/' }]
  : mediaQuery(selector);
mediaLinked.photoMedia.closest = selector => selector === 'a[href]'
  ? { getAttribute: () => '/p/media_123/' } : mediaLinked.article;
mediaLinked.step(1000); mediaLinked.step(1000);
assert.equal(mediaLinked.messages.find(x => x.event === 'impression').permalink,
  'https://www.instagram.com/p/media_123/',
  'a link around the visible media takes precedence over other card links');

for (const options of [
  { route: '/explore/' }, { href: 'https://evil.example/p/example_123/' },
    { href: '/direct/inbox/' }, { visible: false }
]) {
  const attempt = scenario(options);
  attempt.step(1000);
  attempt.step(1000);
  assert.equal(attempt.messages.filter(x => x.event === 'impression').length, 0,
    JSON.stringify(options));
}

(async () => {
  const received = [];
  const scheduled = [];
  const data = { data: { xdt_api__v1__feed__timeline__connection: { edges: [
    { node: { media_or_ad: { code: 'example_123', id: '1234567890123_998877', image_versions2: { candidates: [
      { url: 'https://scontent.cdninstagram.com/v/t51.2885-15/1234567890123_s320x320_n.jpg?size=small' }
    ] }, user: {
      username: 'city_archive', friendship_status: { following: true }
    }, caption: { text: 'Garden notes #flowers #Vienna' },
    video_duration: 10, media_type: 2 } } }
  ] } } };
  const response = { clone: () => ({ json: async () => data }) };
  let currentResponse = response;
  const preloaded = { textContent: JSON.stringify({ require: [{ preload: { result: data } }] }) };
  const document = {
    readyState: 'loading',
    querySelectorAll: () => [preloaded],
    addEventListener(name, handler) { if (name === 'DOMContentLoaded') this.ready = handler; }
  };
  const window = {
    webkit: { messageHandlers: { feedMetadata: { postMessage: value => received.push(value) } } },
    fetch: async () => currentResponse
  };
  class XHR { open() {} send() {} addEventListener() {} }
  const context = { window, document, setTimeout: fn => scheduled.push(fn), location: { hostname: 'www.instagram.com',
    href: 'https://www.instagram.com/' }, URL, XMLHttpRequest: XHR };
  vm.runInNewContext(metadataSource, context);
  document.ready();
  while (scheduled.length) scheduled.shift()();
  assert.equal(received.length, 1, 'preloaded feed metadata is available on first load');
  assert.equal(received[0].caption, 'Garden notes #flowers #Vienna');
  assert.equal(Array.from(received[0].hashtags).join(','), '#flowers,#Vienna');
  assert(received[0].mediaKeys.some(key => unidentified.mediaKeys.includes(key)),
    'the visible unlinked video can be joined to its feed identity');
  assert(received[0].mediaKeys.includes('i_1234567890123'),
    'numeric media IDs are available for safe matching when the page exposes one');
  received.length = 0;
  assert.equal(await window.fetch('https://www.instagram.com/graphql/query'), response,
    'the original network response must be returned unchanged');
  await new Promise(resolve => setTimeout(resolve, 0));
  while (scheduled.length) scheduled.shift()();
  assert.equal(received.length, 1);
  assert.equal(received[0].relationship, 'Followed');
  assert.equal(received[0].videoDuration, 10);
  assert(!('user' in received[0]) && !('cookie' in received[0]));
  received.length = 0;
  const suggestions = { data: { home: { suggested_posts: { edges: [
    { node: { media_or_ad: { permalink: 'https://www.instagram.com/reel/suggested_123/', product_type: 'clips',
      media_type: 2, user: { username: 'happymealjournal' },
      image_versions2: { candidates: [
        { url: 'https://scontent.cdninstagram.com/v/t51.2885-15/7654321098765_n.jpg' }
      ] }
    } } }
  ] } } } };
  currentResponse = { clone: () => ({ json: async () => suggestions }) };
  await window.fetch('https://www.instagram.com/api/v1/feed/timeline/');
  await new Promise(resolve => setTimeout(resolve, 0));
  while (scheduled.length) scheduled.shift()();
  assert.equal(received.length, 1, 'nested suggested posts are extracted');
  assert.equal(received[0].label, 'Suggested');
  assert.equal(received[0].permalink, 'https://www.instagram.com/reel/suggested_123/');
  console.log('Recorder checks passed: startup enable, scan errors, 70 reused cards, pause and resume, identity updates, interactions, metadata, and no image capture.');
})().catch(error => { console.error(error); process.exitCode = 1; });
