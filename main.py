__version__ = "3.0.0"

import json
import threading
import urllib.request
import urllib.error
from datetime import datetime

from kivy.app import App
from kivy.metrics import dp
from kivy.core.window import Window
from kivy.lang import Builder
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.popup import Popup
from kivy.uix.label import Label
from kivy.uix.textinput import TextInput
from kivy.uix.button import Button
from kivy.storage.jsonstore import JsonStore

Window.clearcolor = (0.035, 0.045, 0.065, 1)

KV = r"""
<RootUI>:
    orientation: "vertical"
    padding: dp(12)
    spacing: dp(8)
    canvas.before:
        Color:
            rgba: 0.035, 0.045, 0.065, 1
        Rectangle:
            pos: self.pos
            size: self.size
    BoxLayout:
        size_hint_y: None
        height: dp(48)
        Label:
            text: "[b]Molay AI[/b]  [size=12]v3[/size]"
            markup: True
            font_size: "23sp"
            color: 0.55, 0.78, 1, 1
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
        background_color: 0.07, 0.085, 0.12, 1
        foreground_color: 0.9, 0.92, 0.96, 1
        cursor_color: 0.55, 0.78, 1, 1
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
        background_color: 0.09, 0.11, 0.15, 1
        foreground_color: 1, 1, 1, 1
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

class RootUI(BoxLayout):
    pass

class MolayApp(App):
    title = "Molay AI"
    mode = "chat"
    status = "جاهز — اضبط عنوان الخادم ومفتاح API أولًا"
    transcript = "مولاي، أنا Molay AI v3.\nأستطيع المحادثة والبحث الحي وتوليد الشيفرات عبر الخادم الذي تضبطه.\n"
    def build(self):
        self.store = JsonStore(self.user_data_dir + "/settings.json")
        defaults = {
            "server_url": "http://192.168.1.20:8000",
            "api_key": "",
            "model": "",
            "save_history": True
        }
        if not self.store.exists("settings"):
            self.store.put("settings", **defaults)
        self.settings = self.store.get("settings")
        self.root_ui = Builder.load_string(KV)
        return self.root_ui

    def _request(self, path, payload):
        url = self.settings["server_url"].rstrip("/") + path
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={
            "Content-Type": "application/json",
            "X-API-Key": self.settings.get("api_key", "")
        }, method="POST")
        with urllib.request.urlopen(req, timeout=180) as response:
            return json.loads(response.read().decode("utf-8"))

    def submit(self):
        message = self.root_ui.ids.prompt.text.strip()
        if not message:
            self.status = "اكتب طلبًا أولًا"
            return
        self.root_ui.ids.prompt.text = ""
        self.transcript += f"\n\nأنت: {message}\n\nMolay AI: جارٍ العمل...\n"
        self.root_ui.ids.output.text = self.transcript
        self.status = "أبحث وأعالج طلبك..."
        payload = {
            "message": message,
            "use_search": self.root_ui.ids.live_search.active,
            "use_tor": self.root_ui.ids.tor_search.active,
            "mode": self.mode,
            "model": self.settings.get("model") or None
        }
        threading.Thread(target=self._worker, args=(payload,), daemon=True).start()

    def _worker(self, payload):
        try:
            result = self._request("/ask", payload)
            answer = result.get("answer", "لا توجد إجابة.")
            sources = result.get("sources", [])
            if sources:
                answer += "\n\nالمصادر التي استُرجعت:\n" + "\n".join(
                    f"- {x.get('title','')} — {x.get('url','')}" for x in sources[:7])
            self._append_result(answer, "اكتمل")
        except Exception as e:
            self._append_result("تعذّر الاتصال بالخادم:\n" + str(e) +
                "\n\nتحقق من عنوان الخادم، الشبكة، API Key، وتشغيل Ollama والخادم.", "فشل الاتصال")

    def _append_result(self, answer, status):
        def update(*_):
            self.transcript += answer + "\n"
            self.root_ui.ids.output.text = self.transcript
            self.root_ui.ids.output.cursor = (0, 0)
            self.status = status
            if self.settings.get("save_history", True):
                self.store.put("history", transcript=self.transcript)
        from kivy.clock import Clock
        Clock.schedule_once(update, 0)

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
            result = self._request("/search", payload)
            items = result.get("results", [])
            answer = "\n".join(f"{i+1}. {x.get('title')}\n{x.get('url')}\n{x.get('snippet','')}"
                               for i, x in enumerate(items)) or "لم تُعثر على نتائج."
            self._append_result(answer, f"اكتمل البحث — {len(items)} نتيجة")
        except Exception as e:
            self._append_result("فشل البحث: " + str(e), "فشل البحث")

    def open_settings(self):
        content = BoxLayout(orientation="vertical", padding=dp(10), spacing=dp(8))
        server = TextInput(text=self.settings.get("server_url", ""), hint_text="عنوان الخادم", multiline=False)
        key = TextInput(text=self.settings.get("api_key", ""), hint_text="API Key", multiline=False, password=True)
        model = TextInput(text=self.settings.get("model", ""), hint_text="اسم النموذج (اختياري)", multiline=False)
        content.add_widget(Label(text="عنوان الخادم مثال: http://192.168.1.20:8000", size_hint_y=None, height=dp(30)))
        content.add_widget(server); content.add_widget(key); content.add_widget(model)
        save = Button(text="حفظ", size_hint_y=None, height=dp(46))
        content.add_widget(save)
        popup = Popup(title="إعدادات Molay AI", content=content, size_hint=(0.94, 0.62))
        def do_save(*_):
            self.settings.update({"server_url": server.text.strip(), "api_key": key.text.strip(),
                                  "model": model.text.strip()})
            self.store.put("settings", **self.settings)
            self.status = "تم حفظ الإعدادات"
            popup.dismiss()
        save.bind(on_release=do_save)
        popup.open()

    def clear_screen(self):
        self.transcript = "تم مسح الشاشة.\n"
        self.root_ui.ids.output.text = self.transcript

if __name__ == "__main__":
    MolayApp().run()
