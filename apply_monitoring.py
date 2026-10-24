#!/usr/bin/env python3
"""يدرج مقطع المراقبة في نسخة من index.html (لا يعدّل الأصل). الاستعمال:
   python3 apply_monitoring.py index.html index_monitored.html
يفعل ثلاثة أشياء: (1) يدرج المقطع بعد سكربت __hbAddErr في <head>، (2) يضيف Mon.user في startApp،
(3) يسمح لـ sentry في CSP إن وُجدت سياسة CSP. آمن لإعادة التشغيل."""
import sys, re
src, dst = sys.argv[1], sys.argv[2]
h = open(src, encoding='utf-8').read()
snip = open(__file__.rsplit('/',1)[0] + '/monitoring_snippet.html' if '/' in __file__ else 'monitoring_snippet.html', encoding='utf-8').read()
if '[MON-BEGIN]' in h:
    print('already applied'); sys.exit(0)
anchor = '<link rel="manifest"'
assert h.count(anchor) == 1, 'manifest anchor not unique'
h = h.replace(anchor, snip + anchor, 1)
a = 'function startApp(role){'
assert h.count(a) == 1, 'startApp not unique'
h = h.replace(a, a + "try{if(window.Mon)Mon.user(S.profile);}catch(_e){}", 1)
m = re.search(r'<meta http-equiv="Content-Security-Policy" content="([^"]*)"', h)
if m:
    csp = m.group(1)
    csp2 = re.sub(r"script-src ", "script-src https://browser.sentry-cdn.com ", csp, 1)
    csp2 = re.sub(r"connect-src ", "connect-src https://*.ingest.sentry.io https://*.ingest.de.sentry.io ", csp2, 1)
    h = h.replace(csp, csp2, 1); print('CSP updated')
open(dst, 'w', encoding='utf-8').write(h); print('written', dst)
