# اختبار سريع

بعد تشغيل الخادم وضبط API_KEY:

```bash
curl http://127.0.0.1:8000/health
curl -X POST http://127.0.0.1:8000/search \
  -H 'Content-Type: application/json' \
  -H 'X-API-Key: YOUR_API_KEY' \
  -d '{"query":"Python 3.14 release notes","use_tor":false,"limit":5}'
curl -X POST http://127.0.0.1:8000/ask \
  -H 'Content-Type: application/json' \
  -H 'X-API-Key: YOUR_API_KEY' \
  -d '{"message":"اكتب مثال Python يقرأ ملف JSON","use_search":true,"use_tor":false,"mode":"code"}'
```

## فحص Tor
شغّل Tor daemon على الخادم واجعل `TOR_SOCKS_PROXY=socks5h://127.0.0.1:9050` في `.env`.
ثم أرسل طلب بحث مع `use_tor: true`. إذا لم يكن البروكسي متاحًا، سيظهر خطأ اتصال.
