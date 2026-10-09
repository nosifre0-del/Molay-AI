"""
Molay AI v5 (NYXS) — ملف واحد يجمع الخادم وتطبيق أندرويد.

الاستخدام:
  الخادم  :  pip install fastapi "uvicorn[standard]" "httpx[socks]" beautifulsoup4 python-dotenv pydantic
             python main.py server            (يقرأ الإعدادات من متغيرات البيئة أو ملف .env)
  التطبيق :  pip install kivy
             python main.py app               (على أندرويد يعمل التطبيق تلقائيًا)

متغيرات البيئة للخادم:
  API_KEY (إلزامي، سر طويل عشوائي)   OLLAMA_URL=http://127.0.0.1:11434
  OLLAMA_MODEL=qwen2.5-coder:7b       SEARXNG_URL=   TOR_SOCKS_PROXY=socks5h://127.0.0.1:9050
  ALLOW_DDG_FALLBACK=true             STABILITY_API_KEY=   HOST=127.0.0.1   PORT=8000

بناء APK: ضع هذا الملف باسم main.py داخل مجلد android مع buildozer.spec التالي:
  [app]
  title = Molay AI
  package.name = molayai
  package.domain = org.molay
  source.dir = .
  source.include_exts = py,png,jpg,jpeg,kv,atlas
  version = 5.0.0
  requirements = python3,kivy,pyjnius
  icon.filename = icon.png
  orientation = portrait
  android.permissions = INTERNET
  android.api = 35
  android.minapi = 23
  android.archs = arm64-v8a, armeabi-v7a
  android.accept_sdk_license = True
  (وللاتصال بخادم http بدون TLS أضف: android.manifest.application_attributes = android:usesCleartextTraffic="true")
ثم: buildozer android debug   (أو عبر GitHub Actions: ArtemSBulgakov/buildozer-action@v1 مع workdir: android)

ملاحظة: الاستيرادات الثقيلة داخل الدوال، فلا يحتاج APK إلى مكتبات الخادم ولا العكس.
"""
__version__ = "5.0.0"

import os
import sys
import re
import json
import time
import base64
import threading
import urllib.request

# ════════════════════════════════════════════════════════════════
#  الجزء الأول: الخادم (FastAPI + Ollama + بحث + Tor + صور)
# ════════════════════════════════════════════════════════════════

SYSTEM_PROMPT = (
    "أنت Molay AI، مساعد عربي عملي. إذا سُئلت عن مالكك فأجب: NYXS. استخدم نتائج البحث المرفقة عند توفرها، "
    "واذكر الروابط التي تدعم الادعاءات الحديثة. لا تختلق مصادر أو تواريخ أو اختبارات. "
    "في البرمجة قدّم كودًا واضحًا، واذكر المتطلبات وطريقة التشغيل والاختبارات. "
    "لا تنفذ الشيفرات بنفسك ولا توحِ بأنها اختُبرت ما لم يحدث ذلك فعلًا. "
    "ارفض المساعدة في البرمجيات الخبيثة وسرقة الحسابات والبيانات أو تعطيل الأنظمة.")

PLACEHOLDER_KEY = "replace-this-with-a-long-random-secret"


def build_server_app():
    import asyncio
    import hmac
    from typing import Optional
    from urllib.parse import quote_plus

    import httpx
    from bs4 import BeautifulSoup
    from dotenv import load_dotenv
    from fastapi import FastAPI, Header, HTTPException
    from pydantic import BaseModel, Field

    load_dotenv()
    API_KEY = os.getenv("API_KEY", PLACEHOLDER_KEY)
    OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
    OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5-coder:7b")
    SEARXNG_URL = os.getenv("SEARXNG_URL", "").strip().rstrip("/")
    TOR_SOCKS_PROXY = os.getenv("TOR_SOCKS_PROXY", "").strip()
    ALLOW_DDG = os.getenv("ALLOW_DDG_FALLBACK", "true").lower() == "true"
    STABILITY_API_KEY = os.getenv("STABILITY_API_KEY", "").strip()

    app = FastAPI(title="Molay AI API", version=__version__)

    class AskRequest(BaseModel):
        message: str = Field(min_length=1, max_length=12000)
        use_search: bool = True
        use_tor: bool = False
        mode: str = "chat"  # chat | code
        model: Optional[str] = None

    class ImageRequest(BaseModel):
        prompt: str = Field(min_length=3, max_length=2000)
        aspect_ratio: str = Field(default="1:1",
                                  pattern="^(1:1|16:9|9:16|3:2|2:3|4:5|5:4|4:3|3:4)$")

    class SearchRequest(BaseModel):
        query: str = Field(min_length=1, max_length=500)
        use_tor: bool = False
        limit: int = Field(default=8, ge=1, le=15)

    def require_key(k: Optional[str]):
        if not API_KEY or API_KEY == PLACEHOLDER_KEY:
            raise HTTPException(503, "Set a strong API_KEY before use.")
        if not k or not hmac.compare_digest(k, API_KEY):
            raise HTTPException(401, "Invalid API key.")

    def clean(s):
        return re.sub(r"\s+", " ", s or "").strip()

    def client_for(use_tor):
        headers = {"User-Agent": "MolayAI/5.0 research client"}
        if use_tor:
            if not TOR_SOCKS_PROXY:
                raise HTTPException(400, "Tor is not configured on the server.")
            return httpx.AsyncClient(proxy=TOR_SOCKS_PROXY, timeout=35.0,
                                     follow_redirects=True, headers=headers)
        return httpx.AsyncClient(timeout=20.0, follow_redirects=True, headers=headers)

    async def s_searxng(q, tor, limit):
        if not SEARXNG_URL:
            return []
        try:
            async with client_for(tor) as c:
                r = await c.get(SEARXNG_URL + "/search",
                                params={"q": q, "format": "json", "language": "all"})
                r.raise_for_status()
                return [{"title": clean(i.get("title"))[:300], "url": i.get("url", ""),
                         "snippet": clean(i.get("content"))[:900], "source": "SearXNG"}
                        for i in r.json().get("results", [])[:limit]]
        except HTTPException:
            raise
        except Exception:
            return []

    async def s_ddg(q, tor, limit):
        if not ALLOW_DDG:
            return []
        try:
            async with client_for(tor) as c:
                r = await c.get("https://html.duckduckgo.com/html/", params={"q": q})
                r.raise_for_status()
                soup = BeautifulSoup(r.text, "html.parser")
                out = []
                for res in soup.select(".result")[:limit]:
                    a, sn = res.select_one(".result__a"), res.select_one(".result__snippet")
                    if not a:
                        continue
                    title, href = clean(a.get_text(" ", strip=True)), a.get("href", "")
                    if title and href:
                        out.append({"title": title[:300], "url": href,
                                    "snippet": clean(sn.get_text(" ", strip=True))[:900] if sn else "",
                                    "source": "DuckDuckGo"})
                return out
        except HTTPException:
            raise
        except Exception:
            return []

    async def s_wiki(q, tor, limit):
        try:
            async with client_for(tor) as c:
                r = await c.get("https://en.wikipedia.org/w/api.php", params={
                    "action": "query", "list": "search", "srsearch": q,
                    "format": "json", "srlimit": min(limit, 5)})
                r.raise_for_status()
                out = []
                for i in r.json().get("query", {}).get("search", []):
                    t = i.get("title", "")
                    out.append({
                        "title": "Wikipedia: " + t,
                        "url": "https://en.wikipedia.org/wiki/" + quote_plus(t.replace(" ", "_")),
                        "snippet": clean(BeautifulSoup(i.get("snippet", ""), "html.parser")
                                         .get_text(" "))[:700],
                        "source": "Wikipedia"})
                return out
        except HTTPException:
            raise
        except Exception:
            return []

    async def search_web(q, tor=False, limit=8):
        tasks = [s_searxng(q, tor, limit)]
        if not SEARXNG_URL or ALLOW_DDG:
            tasks.append(s_ddg(q, tor, limit))
        tasks.append(s_wiki(q, tor, limit))
        batches = await asyncio.gather(*tasks)  # أخطاء Tor (400) تظهر للمستخدم
        results, seen = [], set()
        for batch in batches:
            for it in batch:
                u = it.get("url", "")
                if u and u not in seen:
                    seen.add(u)
                    results.append(it)
                    if len(results) >= limit:
                        return results
        return results

    def source_context(results):
        if not results:
            return "لم تُسترجع نتائج بحث موثوقة في هذه المحاولة. لا تدّعِ أنك بحثت."
        lines = ["نتائج ويب جُمعت وقت الطلب. تعامل معها كمصادر تحتاج تحققًا، وليست ضمانًا للصحة:"]
        for i, x in enumerate(results, 1):
            lines.append(f"[{i}] {x['title']}\nURL: {x['url']}\nSnippet: {x['snippet']}")
        return "\n\n".join(lines)

    async def ollama_chat(prompt, model=None):
        payload = {"model": model or OLLAMA_MODEL,
                   "messages": [{"role": "system", "content": SYSTEM_PROMPT},
                                {"role": "user", "content": prompt}],
                   "stream": False, "options": {"temperature": 0.2}}
        async with httpx.AsyncClient(timeout=180.0) as c:
            r = await c.post(f"{OLLAMA_URL}/api/chat", json=payload)
            r.raise_for_status()
            return r.json().get("message", {}).get("content", "لم يُرجع النموذج إجابة.")

    @app.get("/health")
    async def health():
        return {"ok": True, "service": "Molay AI", "version": __version__,
                "time_unix": int(time.time()),
                "search_configured": bool(SEARXNG_URL or ALLOW_DDG),
                "tor_configured": bool(TOR_SOCKS_PROXY), "model": OLLAMA_MODEL}

    @app.post("/search")
    async def search(req: SearchRequest, x_api_key: Optional[str] = Header(default=None)):
        require_key(x_api_key)
        return {"query": req.query, "use_tor": req.use_tor, "fetched_at_unix": int(time.time()),
                "results": await search_web(req.query, req.use_tor, req.limit)}

    @app.post("/ask")
    async def ask(req: AskRequest, x_api_key: Optional[str] = Header(default=None)):
        require_key(x_api_key)
        results = await search_web(req.message, req.use_tor, 7) if req.use_search else []
        task = "مهمة برمجية" if req.mode == "code" else "سؤال"
        prompt = (f"{task} المستخدم:\n{req.message}\n\n"
                  f"وضع البحث الحي: {'مفعّل' if req.use_search else 'معطّل'}\n"
                  f"مسار Tor: {'مطلوب' if req.use_tor else 'غير مطلوب'}\n\n"
                  f"{source_context(results)}\n\n"
                  "أجب بالعربية ما لم يطلب المستخدم لغة أخرى. إذا كان الطلب برمجيًا، ابدأ بتوضيح "
                  "الافتراضات ثم أعطِ الملفات أو الكود وطريقة التشغيل والاختبار. "
                  "إذا لم تكفِ المعلومات أو فشل البحث، صرّح بذلك بوضوح.")
        try:
            answer = await ollama_chat(prompt, req.model)
        except httpx.HTTPError as e:
            raise HTTPException(502, f"Could not reach Ollama at {OLLAMA_URL}: {str(e)[:250]}")
        return {"answer": answer, "sources": results, "fetched_at_unix": int(time.time()),
                "model": req.model or OLLAMA_MODEL, "used_search": req.use_search,
                "used_tor": req.use_tor}

    @app.post("/images/generate")
    async def generate_image(req: ImageRequest, x_api_key: Optional[str] = Header(default=None)):
        require_key(x_api_key)
        if not STABILITY_API_KEY:
            raise HTTPException(503, "توليد الصور غير مفعّل: أضف STABILITY_API_KEY إلى إعدادات الخادم.")
        try:
            async with httpx.AsyncClient(timeout=180.0) as c:
                r = await c.post(
                    "https://api.stability.ai/v2beta/stable-image/generate/core",
                    headers={"authorization": f"Bearer {STABILITY_API_KEY}",
                             "accept": "application/json"},
                    data={"prompt": req.prompt, "aspect_ratio": req.aspect_ratio,
                          "output_format": "png"},
                    files={"none": (None, "")})
        except httpx.HTTPError as e:
            raise HTTPException(502, f"تعذر الاتصال بمزود توليد الصور: {str(e)[:200]}")
        if r.status_code >= 400:
            raise HTTPException(r.status_code, "فشل مزود توليد الصور: " + r.text[:300])
        img = r.json().get("image")
        if not img:
            raise HTTPException(502, "لم يرجع مزود الصور صورة صالحة.")
        return {"image_base64": img, "mime_type": "image/png", "prompt": req.prompt}

    return app


def run_server():
    import uvicorn
    uvicorn.run(build_server_app(), host=os.getenv("HOST", "127.0.0.1"),
                port=int(os.getenv("PORT", "8000")))


# ════════════════════════════════════════════════════════════════
#  الجزء الثاني: تطبيق Kivy (أندرويد / سطح المكتب)
# ════════════════════════════════════════════════════════════════

KV = r"""
<RootUI>:
    orientation: "vertical"
    padding: dp(12)
    spacing: dp(8)
    canvas.before:
        Color:
            rgba: 0.035, 0.025, 0.065, 1
        Rectangle:
            pos: self.pos
            size: self.size
    BoxLayout:
        size_hint_y: None
        height: dp(48)
        Label:
            text: "[b]Molay AI[/b]  [size=12]v5[/size]"
            markup: True
            font_size: "23sp"
            color: 0.78, 0.55, 1, 1
            halign: "left"
            text_size: self.size
        Button:
            text: "الإعدادات"
            size_hint_x: None
            width: dp(100)
            on_release: app.open_settings()
    BoxLayout:
        size_hint_y: None
        height: dp(44)
        spacing: dp(6)
        Button:
            text: "محادثة"
            on_release: app.mode = "chat"; app.status = "وضع المحادثة"
        Button:
            text: "برمجة"
            on_release: app.mode = "code"; app.status = "وضع البرمجة"
        Button:
            text: "بحث"
            on_release: app.run_search()
        Button:
            text: "توليد صورة"
            on_release: app.generate_image()
    BoxLayout:
        size_hint_y: None
        height: dp(38)
        spacing: dp(8)
        CheckBox:
            id: live_search
            size_hint_x: None
            width: dp(42)
            active: True
        Label:
            text: "بحث ويب حي"
            size_hint_x: None
            width: dp(100)
            halign: "left"
            text_size: self.size
        CheckBox:
            id: tor_search
            size_hint_x: None
            width: dp(42)
            active: False
        Label:
            text: "Tor (يتطلب إعداد الخادم)"
            halign: "left"
            text_size: self.size
    TextInput:
        id: output
        text: app.transcript
        readonly: True
        multiline: True
        size_hint_y: 1
        background_color: 0.075, 0.045, 0.11, 1
        foreground_color: 0.9, 0.92, 0.96, 1
        cursor_color: 0.9, 0.72, 0.25, 1
        padding: dp(10)
        font_size: "15sp"
    Label:
        text: app.status
        size_hint_y: None
        height: dp(25)
        color: 0.55, 0.78, 1, 1
        halign: "left"
        text_size: self.size
    TextInput:
        id: prompt
        hint_text: "اكتب سؤالك أو ما تريد برمجته..."
        multiline: True
        size_hint_y: None
        height: dp(100)
        background_color: 0.10, 0.065, 0.12, 1
        foreground_color: 1, 1, 1, 1
        cursor_color: 0.95, 0.72, 0.2, 1
        padding: dp(10)
    BoxLayout:
        size_hint_y: None
        height: dp(48)
        spacing: dp(8)
        Button:
            text: "إرسال"
            on_release: app.submit()
        Button:
            text: "مسح الشاشة"
            on_release: app.clear_screen()
"""


def run_app():
    from kivy.app import App
    from kivy.clock import Clock
    from kivy.core.window import Window
    from kivy.lang import Builder
    from kivy.metrics import dp
    from kivy.properties import StringProperty
    from kivy.storage.jsonstore import JsonStore
    from kivy.uix.boxlayout import BoxLayout
    from kivy.uix.button import Button
    from kivy.uix.checkbox import CheckBox  # كان مفقودًا في النسخة السابقة
    from kivy.uix.image import Image
    from kivy.uix.label import Label
    from kivy.uix.popup import Popup
    from kivy.uix.textinput import TextInput
    from kivy.utils import platform

    Window.clearcolor = (0.035, 0.025, 0.065, 1)

    class RootUI(BoxLayout):
        pass

    class MolayApp(App):
        title = "Molay AI"
        mode = StringProperty("chat")
        status = StringProperty("جاهز — اضبط عنوان الخادم ومفتاح API أولًا")
        transcript = StringProperty(
            "مولاي، أنا Molay AI v5.\nأستطيع المحادثة والبحث الحي وتوليد الشيفرات عبر الخادم الذي تضبطه.\n")

        def build(self):
            self.store = JsonStore(os.path.join(self.user_data_dir, "settings.json"))
            if not self.store.exists("settings"):
                self.store.put("settings", server_url="http://192.168.1.20:8000", api_key="",
                               model="", save_history=True, speak_replies=True)
            self.settings = dict(self.store.get("settings"))
            self.root_ui = Builder.load_string(KV)
            self.tts = self._init_tts() if platform == "android" else None
            return self.root_ui

        # ---- صوت أندرويد (TTS) ----
        def _init_tts(self):
            try:
                from jnius import autoclass, PythonJavaClass, java_method
                PythonActivity = autoclass("org.kivy.android.PythonActivity")
                TextToSpeech = autoclass("android.speech.tts.TextToSpeech")

                class InitListener(PythonJavaClass):
                    __javainterfaces__ = ["android/speech/tts/TextToSpeech$OnInitListener"]
                    __javacontext__ = "app"

                    @java_method("(I)V")
                    def onInit(self, status):
                        pass

                self._tts_listener = InitListener()  # إبقاء مرجع حتى لا يُجمع
                return TextToSpeech(PythonActivity.mActivity, self._tts_listener)
            except Exception:
                return None

        def speak(self, text):
            try:
                if self.tts:
                    self.tts.speak(text, 0, None, "molay_reply")
            except Exception:
                pass

        # ---- الشبكة ----
        def _request(self, path, payload):
            url = self.settings["server_url"].rstrip("/") + path
            req = urllib.request.Request(
                url, data=json.dumps(payload).encode("utf-8"), method="POST",
                headers={"Content-Type": "application/json",
                         "X-API-Key": self.settings.get("api_key", "")})
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.loads(r.read().decode("utf-8"))

        def _show(self, text):
            self.root_ui.ids.output.text = self.transcript

        def _append_result(self, answer, status):
            def update(*_):
                self.transcript += answer + "\n"
                self.root_ui.ids.output.text = self.transcript
                self.root_ui.ids.output.cursor = (0, 0)
                self.status = status
                if self.settings.get("speak_replies", True):
                    self.speak(answer[:1200])
                if self.settings.get("save_history", True):
                    self.store.put("history", transcript=self.transcript)
            Clock.schedule_once(update, 0)

        # ---- الأوامر ----
        def submit(self):
            message = self.root_ui.ids.prompt.text.strip()
            if not message:
                self.status = "اكتب طلبًا أولًا"
                return
            self.root_ui.ids.prompt.text = ""
            self.transcript += f"\n\nأنت: {message}\n\nMolay AI: جارٍ العمل...\n"
            self.root_ui.ids.output.text = self.transcript
            self.status = "أبحث وأعالج طلبك..."
            payload = {"message": message,
                       "use_search": self.root_ui.ids.live_search.active,
                       "use_tor": self.root_ui.ids.tor_search.active,
                       "mode": self.mode, "model": self.settings.get("model") or None}
            threading.Thread(target=self._worker, args=(payload,), daemon=True).start()

        def _worker(self, payload):
            try:
                result = self._request("/ask", payload)
                answer = result.get("answer", "لا توجد إجابة.")
                sources = result.get("sources", [])
                if sources:
                    answer += "\n\nالمصادر التي استُرجعت:\n" + "\n".join(
                        f"- {x.get('title', '')} — {x.get('url', '')}" for x in sources[:7])
                self._append_result(answer, "اكتمل")
            except Exception as e:
                self._append_result(
                    "تعذّر الاتصال بالخادم:\n" + str(e) +
                    "\n\nتحقق من عنوان الخادم، الشبكة، API Key، وتشغيل Ollama والخادم.", "فشل الاتصال")

        def run_search(self):
            query = self.root_ui.ids.prompt.text.strip()
            if not query:
                self.status = "اكتب عبارة البحث في مربع الرسالة"
                return
            self.root_ui.ids.prompt.text = ""
            self.transcript += f"\n\nبحث: {query}\n"
            self.root_ui.ids.output.text = self.transcript
            self.status = "جارٍ البحث..."
            payload = {"query": query, "use_tor": self.root_ui.ids.tor_search.active, "limit": 10}
            threading.Thread(target=self._search_worker, args=(payload,), daemon=True).start()

        def _search_worker(self, payload):
            try:
                items = self._request("/search", payload).get("results", [])
                answer = "\n".join(
                    f"{i + 1}. {x.get('title')}\n{x.get('url')}\n{x.get('snippet', '')}"
                    for i, x in enumerate(items)) or "لم تُعثر على نتائج."
                self._append_result(answer, f"اكتمل البحث — {len(items)} نتيجة")
            except Exception as e:
                self._append_result("فشل البحث: " + str(e), "فشل البحث")

        def generate_image(self):
            prompt = self.root_ui.ids.prompt.text.strip()
            if not prompt:
                self.status = "اكتب وصف الصورة أولًا"
                return
            self.root_ui.ids.prompt.text = ""
            self.transcript += f"\n\nطلب توليد صورة: {prompt}\nMolay AI: جارٍ توليد الصورة...\n"
            self.root_ui.ids.output.text = self.transcript
            self.status = "توليد الصورة عبر الخادم..."
            threading.Thread(target=self._image_worker, args=(prompt,), daemon=True).start()

        def _image_worker(self, prompt):
            try:
                result = self._request("/images/generate", {"prompt": prompt, "aspect_ratio": "1:1"})
                path = os.path.join(self.user_data_dir, "molay_generated.png")
                with open(path, "wb") as f:
                    f.write(base64.b64decode(result["image_base64"]))
                self._append_result("تم توليد الصورة وحفظها داخل بيانات التطبيق: " + path,
                                    "اكتمل توليد الصورة")

                def show(*_):
                    box = BoxLayout()
                    box.add_widget(Image(source=path, allow_stretch=True, keep_ratio=True))
                    Popup(title="صورة Molay AI", content=box, size_hint=(0.95, 0.85)).open()
                Clock.schedule_once(show, 0.2)
            except Exception as e:
                self._append_result("تعذّر توليد الصورة: " + str(e) +
                                    "\nتأكد من ضبط STABILITY_API_KEY على الخادم.", "تعذّر توليد الصورة")

        def open_settings(self):
            content = BoxLayout(orientation="vertical", padding=dp(10), spacing=dp(8))
            server = TextInput(text=self.settings.get("server_url", ""), hint_text="عنوان الخادم",
                               multiline=False)
            key = TextInput(text=self.settings.get("api_key", ""), hint_text="API Key",
                            multiline=False, password=True)
            model = TextInput(text=self.settings.get("model", ""), hint_text="اسم النموذج (اختياري)",
                              multiline=False)
            voice = CheckBox(active=self.settings.get("speak_replies", True),
                             size_hint_y=None, height=dp(40))
            content.add_widget(Label(text="قراءة الردود بصوت الهاتف", size_hint_y=None, height=dp(28)))
            content.add_widget(voice)
            content.add_widget(Label(text="عنوان الخادم مثال: http://192.168.1.20:8000",
                                     size_hint_y=None, height=dp(30)))
            for w in (server, key, model):
                content.add_widget(w)
            save = Button(text="حفظ", size_hint_y=None, height=dp(46))
            content.add_widget(save)
            popup = Popup(title="إعدادات Molay AI", content=content, size_hint=(0.94, 0.62))

            def do_save(*_):
                self.settings.update({"server_url": server.text.strip(), "api_key": key.text.strip(),
                                      "model": model.text.strip(), "speak_replies": voice.active})
                self.store.put("settings", **self.settings)
                self.status = "تم حفظ الإعدادات"
                popup.dismiss()
            save.bind(on_release=do_save)
            popup.open()

        def clear_screen(self):
            self.transcript = "تم مسح الشاشة.\n"
            self.root_ui.ids.output.text = self.transcript

    MolayApp().run()


# ════════════════════════════════════════════════════════════════
#  نقطة الدخول
# ════════════════════════════════════════════════════════════════

def _is_android():
    return "ANDROID_ARGUMENT" in os.environ or "ANDROID_PRIVATE" in os.environ


if __name__ == "__main__":
    arg = sys.argv[1].lower() if len(sys.argv) > 1 else ""
    if _is_android() or arg == "app":
        run_app()
    elif arg == "server":
        run_server()
    else:
        print("الاستخدام:\n  python main.py server   # تشغيل الخادم\n  python main.py app      # تشغيل التطبيق")
