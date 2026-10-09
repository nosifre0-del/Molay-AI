import os
import re
import time
from typing import Optional
from urllib.parse import quote_plus, urlparse

import httpx
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

load_dotenv()
app = FastAPI(title="Molay AI Search & Code API", version="3.0.0")

API_KEY = os.getenv("API_KEY", "replace-this-with-a-long-random-secret")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5-coder:7b")
SEARXNG_URL = os.getenv("SEARXNG_URL", "").strip().rstrip("/")
TOR_SOCKS_PROXY = os.getenv("TOR_SOCKS_PROXY", "").strip()
ALLOW_DDG_FALLBACK = os.getenv("ALLOW_DDG_FALLBACK", "true").lower() == "true"

class AskRequest(BaseModel):
    message: str = Field(min_length=1, max_length=12000)
    use_search: bool = True
    use_tor: bool = False
    mode: str = "chat"  # chat or code
    model: Optional[str] = None

class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=500)
    use_tor: bool = False
    limit: int = Field(default=8, ge=1, le=15)

def require_key(x_api_key: Optional[str]):
    if not API_KEY or API_KEY == "replace-this-with-a-long-random-secret":
        raise HTTPException(503, "Set a strong API_KEY in backend/.env before use.")
    if x_api_key != API_KEY:
        raise HTTPException(401, "Invalid API key.")

def clean_text(s: str) -> str:
    return re.sub(r"\s+", " ", s or "").strip()

async def get_client(use_tor: bool = False):
    if use_tor:
        if not TOR_SOCKS_PROXY:
            raise HTTPException(400, "Tor is not configured on the server.")
        # socks5h delegates DNS resolution to Tor.
        return httpx.AsyncClient(proxy=TOR_SOCKS_PROXY, timeout=35.0, follow_redirects=True,
                                 headers={"User-Agent": "MolayAI/3.0 research client"})
    return httpx.AsyncClient(timeout=20.0, follow_redirects=True,
                             headers={"User-Agent": "MolayAI/3.0 research client"})

async def search_searxng(query: str, use_tor: bool, limit: int):
    if not SEARXNG_URL:
        return []
    client = await get_client(use_tor)
    async with client:
        url = SEARXNG_URL + "/search"
        try:
            r = await client.get(url, params={"q": query, "format": "json", "language": "all"})
            r.raise_for_status()
            data = r.json()
            out = []
            for item in data.get("results", [])[:limit]:
                out.append({
                    "title": clean_text(item.get("title", ""))[:300],
                    "url": item.get("url", ""),
                    "snippet": clean_text(item.get("content", ""))[:900],
                    "source": "SearXNG"
                })
            return out
        except Exception:
            return []

async def search_duckduckgo(query: str, use_tor: bool, limit: int):
    if not ALLOW_DDG_FALLBACK:
        return []
    client = await get_client(use_tor)
    async with client:
        try:
            r = await client.get("https://html.duckduckgo.com/html/", params={"q": query})
            r.raise_for_status()
            soup = BeautifulSoup(r.text, "html.parser")
            out = []
            for result in soup.select(".result")[:limit]:
                a = result.select_one(".result__a")
                sn = result.select_one(".result__snippet")
                if not a:
                    continue
                href = a.get("href", "")
                title = clean_text(a.get_text(" ", strip=True))
                snippet = clean_text(sn.get_text(" ", strip=True)) if sn else ""
                if title and href:
                    out.append({"title": title[:300], "url": href,
                                "snippet": snippet[:900], "source": "DuckDuckGo"})
            return out
        except Exception:
            return []

async def search_wikipedia(query: str, use_tor: bool, limit: int):
    client = await get_client(use_tor)
    async with client:
        try:
            r = await client.get("https://en.wikipedia.org/w/api.php", params={
                "action": "query", "list": "search", "srsearch": query,
                "format": "json", "srlimit": min(limit, 5)
            })
            r.raise_for_status()
            data = r.json()
            out = []
            for item in data.get("query", {}).get("search", []):
                title = item.get("title", "")
                out.append({
                    "title": "Wikipedia: " + title,
                    "url": "https://en.wikipedia.org/wiki/" + quote_plus(title.replace(" ", "_")),
                    "snippet": clean_text(BeautifulSoup(item.get("snippet", ""), "html.parser").get_text(" "))[:700],
                    "source": "Wikipedia"
                })
            return out
        except Exception:
            return []

async def search_web(query: str, use_tor=False, limit=8):
    # Parallel search aggregation, deduplicated by URL.
    import asyncio
    tasks = [search_searxng(query, use_tor, limit)]
    if not SEARXNG_URL or ALLOW_DDG_FALLBACK:
        tasks.append(search_duckduckgo(query, use_tor, limit))
    tasks.append(search_wikipedia(query, use_tor, limit))
    batches = await asyncio.gather(*tasks, return_exceptions=True)
    results, seen = [], set()
    for batch in batches:
        if isinstance(batch, Exception):
            continue
        for item in batch:
            u = item.get("url", "")
            if not u or u in seen:
                continue
            seen.add(u)
            results.append(item)
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

async def ollama_chat(prompt: str, model: Optional[str] = None):
    payload = {
        "model": model or OLLAMA_MODEL,
        "messages": [
            {"role": "system", "content":
             "أنت Molay AI، مساعد عربي عملي. استخدم نتائج البحث المرفقة عند توفرها، "
             "واذكر الروابط التي تدعم الادعاءات الحديثة. لا تختلق مصادر أو تواريخ أو اختبارات. "
             "في البرمجة قدّم كودًا واضحًا، واذكر المتطلبات وطريقة التشغيل والاختبارات. "
             "لا تنفذ الشيفرات بنفسك ولا توحِ بأنها اختُبرت ما لم يحدث ذلك فعلًا. "
             "ارفض المساعدة في البرمجيات الخبيثة وسرقة الحسابات والبيانات أو تعطيل الأنظمة."},
            {"role": "user", "content": prompt}
        ],
        "stream": False,
        "options": {"temperature": 0.2}
    }
    async with httpx.AsyncClient(timeout=180.0) as client:
        r = await client.post(f"{OLLAMA_URL}/api/chat", json=payload)
        r.raise_for_status()
        data = r.json()
        return data.get("message", {}).get("content", "لم يُرجع النموذج إجابة.")

@app.get("/health")
async def health():
    return {"ok": True, "service": "Molay AI v3", "time_unix": int(time.time()),
            "search_configured": bool(SEARXNG_URL or ALLOW_DDG_FALLBACK),
            "tor_configured": bool(TOR_SOCKS_PROXY), "model": OLLAMA_MODEL}

@app.post("/search")
async def search(req: SearchRequest, x_api_key: Optional[str] = Header(default=None)):
    require_key(x_api_key)
    results = await search_web(req.query, req.use_tor, req.limit)
    return {"query": req.query, "use_tor": req.use_tor, "fetched_at_unix": int(time.time()),
            "results": results}

@app.post("/ask")
async def ask(req: AskRequest, x_api_key: Optional[str] = Header(default=None)):
    require_key(x_api_key)
    results = []
    if req.use_search:
        # For code requests, search for the current topic and relevant documentation.
        results = await search_web(req.message, req.use_tor, 7)
    task_type = "مهمة برمجية" if req.mode == "code" else "سؤال"
    prompt = (
        f"{task_type} المستخدم:\n{req.message}\n\n"
        f"وضع البحث الحي: {'مفعّل' if req.use_search else 'معطّل'}\n"
        f"مسار Tor: {'مطلوب' if req.use_tor else 'غير مطلوب'}\n\n"
        f"{source_context(results)}\n\n"
        "أجب بالعربية ما لم يطلب المستخدم لغة أخرى. إذا كان الطلب برمجيًا، "
        "ابدأ بتوضيح الافتراضات ثم أعطِ الملفات أو الكود وطريقة التشغيل والاختبار. "
        "إذا لم تكفِ المعلومات أو فشل البحث، صرّح بذلك بوضوح."
    )
    try:
        answer = await ollama_chat(prompt, req.model)
    except httpx.HTTPError as e:
        raise HTTPException(502, f"Could not reach Ollama at {OLLAMA_URL}: {str(e)[:250]}")
    return {"answer": answer, "sources": results, "fetched_at_unix": int(time.time()),
            "model": req.model or OLLAMA_MODEL, "used_search": req.use_search, "used_tor": req.use_tor}
