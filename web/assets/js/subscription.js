(function () {
  // The customer-facing subscription page. Everything it renders comes from the
  // bootstrap <template> the server fills in; there is no API call, because this page
  // is handed out by URL to people who are not logged into anything.
  const el = document.getElementById('subscription-data');
  if (!el) return;
  const textarea = document.getElementById('subscription-links');
  const rawLinks = (textarea?.value || '').split('\n').filter(Boolean);

  const attr = (name, fallback = '') => el.getAttribute(name) || fallback;
  const num = (name) => parseInt(el.getAttribute(name) || '0', 10) || 0;

  const data = {
    sId: attr('data-sid'),
    subUrl: attr('data-sub-url'),
    subJsonUrl: attr('data-subjson-url'),
    subClashUrl: attr('data-subclash-url'),
    download: attr('data-download'),
    upload: attr('data-upload'),
    used: attr('data-used'),
    total: attr('data-total'),
    remained: attr('data-remained'),
    expireMs: num('data-expire') * 1000,
    lastOnlineMs: num('data-lastonline'),
    downloadByte: num('data-downloadbyte'),
    uploadByte: num('data-uploadbyte'),
    totalByte: num('data-totalbyte'),
    datepicker: attr('data-datepicker', 'gregorian'),
    brand: attr('data-brand'),
    subTitle: attr('data-subtitle'),
  };

  // Normalize lastOnline to milliseconds if it looks like seconds.
  if (data.lastOnlineMs && data.lastOnlineMs < 10_000_000_000) {
    data.lastOnlineMs *= 1000;
  }

  const DAY = 86400000;
  const RING_R = 52;

  function copy(text) {
    if (!text) return;
    ClipboardManager.copyText(text).then(ok => {
      Vue.prototype.$message[ok ? 'success' : 'error'](ok ? 'Copied' : 'Copy failed');
    });
  }

  function open(url) {
    window.location.href = url;
  }

  // QRious throws on an oversized payload rather than returning; a link too long to
  // encode must not take the rest of the page down with it.
  function drawQR(id, value, size = 200) {
    const target = document.getElementById(id);
    if (!target || !value) return;
    try {
      new QRious({ element: target, value, size, padding: 0 });
    } catch (e) {
      console.warn('QR render failed', e);
    }
  }

  // Try to extract a human label (email/ps) from different link types.
  function linkName(link, idx) {
    try {
      if (link.startsWith('vmess://')) {
        const json = JSON.parse(atob(link.replace('vmess://', '')));
        if (json.ps) return json.ps;
        if (json.add && json.id) return json.add; // fallback host
      } else if (link.startsWith('vless://') || link.startsWith('trojan://')) {
        const hashIdx = link.indexOf('#');
        if (hashIdx !== -1) return decodeURIComponent(link.substring(hashIdx + 1));
        const qIdx = link.indexOf('?');
        if (qIdx !== -1) {
          const qs = new URL('http://x/?' + link.substring(qIdx + 1, hashIdx !== -1 ? hashIdx : undefined)).searchParams;
          if (qs.get('remark')) return qs.get('remark');
          if (qs.get('email')) return qs.get('email');
        }
        const at = link.indexOf('@');
        const protSep = link.indexOf('://');
        if (at !== -1 && protSep !== -1) return link.substring(protSep + 3, at);
      } else if (link.startsWith('ss://')) {
        const hashIdx = link.indexOf('#');
        if (hashIdx !== -1) return decodeURIComponent(link.substring(hashIdx + 1));
      } else if (link.startsWith('tg://')) {
        // tg://proxy?server=HOST&port=..&secret=.. -> label with the server host.
        const qs = new URL('http://x/?' + link.substring(link.indexOf('?') + 1)).searchParams;
        const host = qs.get('server');
        return host ? 'MTProto (' + host + ')' : 'MTProto';
      } else if (link.startsWith('ssh://')) {
        // ssh://base64(user:pass@host:port)[#label] -> prefer the #label, else the host.
        const hashIdx = link.indexOf('#');
        if (hashIdx !== -1) return decodeURIComponent(link.substring(hashIdx + 1));
        const decoded = atob(link.substring('ssh://'.length));
        const at = decoded.lastIndexOf('@');
        return 'SSH' + (at !== -1 ? ' (' + decoded.substring(at + 1) + ')' : '');
      } else if (link.startsWith('wireguard://')) {
        // wg-c/awg: wireguard://<privkey>@host:port?..#remark -> the remark names the
        // device; fall back to the endpoint so a link without one still reads.
        const hashIdx = link.indexOf('#');
        if (hashIdx !== -1) return decodeURIComponent(link.substring(hashIdx + 1));
        const at = link.indexOf('@');
        const qIdx = link.indexOf('?');
        return at !== -1 ? 'WireGuard (' + link.substring(at + 1, qIdx === -1 ? undefined : qIdx) + ')'
                         : 'WireGuard';
      }
    } catch (e) { /* ignore and fallback */ }
    return 'Link ' + (idx + 1);
  }

  // The apps a customer can hand this subscription to, per platform.
  //
  // `open` means the app registered a URL scheme that imports a subscription, so the
  // click finishes the job. `copy` means it did not, and the honest thing is to put the
  // link on their clipboard and let them paste it — silently navigating to a scheme
  // nothing handles leaves them on an error page wondering what happened.
  function appsFor(d) {
    const url = d.subUrl;
    const enc = encodeURIComponent(url);
    const name = encodeURIComponent(d.sId || 'Subscription');
    return [
      { name: 'V2RayNG', platforms: ['android'], mode: 'open',
        url: 'v2rayng://install-config?url=' + enc },
      { name: 'V2Box', platforms: ['android', 'ios'], mode: 'open',
        url: 'v2box://install-sub?url=' + enc + '&name=' + name },
      { name: 'Happ', platforms: ['android', 'ios'], mode: 'open',
        url: 'happ://add/' + url },
      { name: 'Hiddify', platforms: ['android', 'ios', 'desktop'], mode: 'open',
        url: 'hiddify://import/' + url },
      { name: 'Sing-box', platforms: ['android', 'ios'], mode: 'open',
        url: 'sing-box://import-remote-profile?url=' + enc },
      { name: 'V2RayTun', platforms: ['android', 'ios'], mode: 'copy' },
      { name: 'NPV Tunnel', platforms: ['android', 'ios'], mode: 'copy' },
      { name: 'Shadowrocket', platforms: ['ios'], mode: 'open',
        url: 'shadowrocket://add/sub/' + btoa(url + '?flag=shadowrocket') + '?remark=' + name },
      { name: 'Streisand', platforms: ['ios'], mode: 'open',
        url: 'streisand://import/' + enc },
      { name: 'v2rayN', platforms: ['desktop'], mode: 'copy' },
      { name: 'Nekoray', platforms: ['desktop'], mode: 'copy' },
      { name: 'Clash / Mihomo', platforms: ['desktop'], mode: 'copy',
        feed: 'clash' },
    ];
  }

  function detectPlatform() {
    const ua = (navigator.userAgent || '').toLowerCase();
    if (/iphone|ipad|ipod/.test(ua)) return 'ios';
    // iPadOS 13+ reports itself as a Mac; a touch-capable "Mac" is an iPad.
    if (/macintosh/.test(ua) && navigator.maxTouchPoints > 1) return 'ios';
    if (/android/.test(ua)) return 'android';
    return 'desktop';
  }

  // The page's own strings. This file is a static asset and cannot see the i18n
  // bundle, so subpage.html renders them into SUB_I18N before loading it; the
  // fallbacks below are only reached if that script were ever dropped.
  const t = Object.assign({
    active: 'Active', expired: 'Expired', depleted: 'Traffic finished',
    unlimited: 'Unlimited', noExpiry: 'No expiry', daysLeft: 'days left',
    feedRaw: 'Standard', desktop: 'Desktop',
  }, window.SUB_I18N || {});

  const app = new Vue({
    delimiters: ['[[', ']]'],
    el: '#app',
    data: {
      themeSwitcher,
      app: data,
      links: rawLinks,
      t,
      lang: '',
      // Which of the subscription's three forms the copy button hands over. The plain
      // one by default: every app understands it, and the other two exist for the
      // minority whose client wants them.
      feed: 'raw',
      platform: detectPlatform(),
      qrOpen: false,
      linksOpen: false,
      // Index of the individual link whose QR is showing, or -1.
      linkQr: -1,
    },
    computed: {
      brandName() {
        return this.app.subTitle || this.app.brand || 'VPN';
      },
      isUnlimited() {
        return !this.app.totalByte;
      },
      usedByte() {
        return this.app.uploadByte + this.app.downloadByte;
      },
      // 0..1 of the allowance spent, which the ring draws the INVERSE of: the arc is
      // what is left, so it shrinks as the account is used up. An unlimited account
      // has nothing to be a fraction of and reads as nothing spent, which draws the
      // ring full — an empty ring beside the word "unlimited" would say the opposite.
      usedRatio() {
        if (this.isUnlimited) return 0;
        return Math.max(0, Math.min(1, this.usedByte / this.app.totalByte));
      },
      daysLeft() {
        if (!this.app.expireMs) return null;
        return Math.ceil((this.app.expireMs - Date.now()) / DAY);
      },
      isExpired() {
        return this.app.expireMs > 0 && this.app.expireMs < Date.now();
      },
      isDepleted() {
        return !this.isUnlimited && this.usedByte >= this.app.totalByte;
      },
      isActive() {
        return !this.isExpired && !this.isDepleted;
      },
      // One word for the whole state, chosen by what will bite the customer first.
      // "warn" is the useful case: still working, but not for much longer.
      statusClass() {
        if (!this.isActive) return 'is-bad';
        const lowTraffic = !this.isUnlimited && this.usedRatio >= 0.9;
        const lowDays = this.daysLeft !== null && this.daysLeft <= 3;
        return (lowTraffic || lowDays) ? 'is-warn' : 'is-ok';
      },
      statusText() {
        if (this.isExpired) return this.t.expired;
        if (this.isDepleted) return this.t.depleted;
        if (this.isUnlimited && !this.app.expireMs) return this.t.unlimited;
        return this.t.active;
      },
      expiryText() {
        if (!this.app.expireMs) return this.t.noExpiry;
        if (this.isExpired) return IntlUtil.formatDate(this.app.expireMs);
        return this.daysLeft + ' ' + this.t.daysLeft;
      },
      ringCircumference() {
        return 2 * Math.PI * RING_R;
      },
      ringOffset() {
        // The arc shows what is LEFT, so it shrinks as the account is spent.
        return this.ringCircumference * this.usedRatio;
      },
      ringLabel() {
        return this.isUnlimited
          ? this.t.unlimited
          : Math.round((1 - this.usedRatio) * 100) + '%';
      },
      // Only the forms this panel actually serves: subJsonUrl and subClashUrl are
      // blanked server-side when their endpoints are disabled, and a tab that leads
      // to a 404 is worse than no tab.
      feeds() {
        const out = [{ key: 'raw', label: this.t.feedRaw, url: this.app.subUrl }];
        if (this.app.subJsonUrl) out.push({ key: 'json', label: 'JSON', url: this.app.subJsonUrl });
        if (this.app.subClashUrl) out.push({ key: 'clash', label: 'Clash', url: this.app.subClashUrl });
        return out;
      },
      currentUrl() {
        const f = this.feeds.find(x => x.key === this.feed);
        return f ? f.url : this.app.subUrl;
      },
      platforms() {
        return [
          { key: 'android', label: 'Android' },
          { key: 'ios', label: 'iOS' },
          { key: 'desktop', label: this.t.desktop },
        ];
      },
      visibleApps() {
        // An app pinned to a feed this panel does not serve (Clash, when the clash
        // endpoint is off) has no link to give, so it is not offered.
        return appsFor(this.app).filter(a =>
          a.platforms.includes(this.platform) &&
          (!a.feed || this.feeds.some(f => f.key === a.feed)));
      },
    },
    methods: {
      copy,
      open,
      linkName,
      selectFeed(key) {
        this.feed = key;
        if (this.qrOpen) this.$nextTick(() => drawQR('sub-qr-canvas', this.currentUrl));
      },
      toggleQr() {
        this.qrOpen = !this.qrOpen;
        // Drawn on open rather than up front: the canvas has no size while hidden, and
        // QRious sizes to the element it is handed.
        if (this.qrOpen) this.$nextTick(() => drawQR('sub-qr-canvas', this.currentUrl));
      },
      toggleLinkQr(idx) {
        this.linkQr = this.linkQr === idx ? -1 : idx;
        if (this.linkQr === idx) {
          this.$nextTick(() => drawQR('sub-link-qr-' + idx, this.links[idx]));
        }
      },
      launch(a) {
        // 'copy' apps import by paste; sending them to an unhandled scheme would
        // leave the customer on a browser error page.
        if (a.mode === 'copy') {
          const url = a.feed
            ? (this.feeds.find(f => f.key === a.feed) || {}).url || this.app.subUrl
            : this.currentUrl;
          copy(url);
          return;
        }
        open(a.url);
      },
    },
    mounted() {
      this.lang = LanguageManager.getLanguage();
    },
  });
})();
