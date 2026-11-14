"""Copy omnigent's built web UI and adapt it to WOOW PaaS (#1358 / #1379).

Runs as the server Pod's init container (same pinned server image). Copies
``omnigent/server/static/web-ui`` to ``$DEST`` (an emptyDir the server serves via
``OMNIGENT_WEB_UI_DIST``), then:

* rewrites the two login-page hints written for a self-installed omnigent
  ("your username is the output of whoami", "no credential is auto-generated")
  into the PaaS flow — the platform creates ``admin`` and shows the initial
  password once at provisioning;
* when ``PAAS_LLM_CONFIGURED`` is ``0`` (runners on, no tenant LLM key), adds a
  dismissible notice that managed sessions cannot answer until a key is filled
  in on the WOOW service page;
* when ``PAAS_EPHEMERAL_WORKSPACE`` is ``1`` (runners on, #1451), adds a
  dismissible notice that a cloud work machine's files are temporary.

Best-effort by design: an upstream wording change leaves the original text (and
logs it); only a failed copy fails the init container.
"""

import json
import os
import re
import shutil
import sys
from pathlib import Path

import omnigent.server as server_pkg

SRC = Path(server_pkg.__file__).parent / "static" / "web-ui"
DEST = Path(os.environ.get("DEST", "/ui"))
LLM_CONFIGURED = os.environ.get("PAAS_LLM_CONFIGURED", "1") == "1"
EPHEMERAL_WORKSPACE = os.environ.get("PAAS_EPHEMERAL_WORKSPACE", "0") == "1"
ADMIN = os.environ.get("ADMIN_USERNAME", "admin")

USERNAME_HINT = re.compile(
    r"\[`On a fresh install your username is your machine login \(the output of`,` `,"
    r"\(0,\w+\.jsx\)\(`code`,\{className:`[^`]*`,children:`whoami`\}\),"
    r"`\), unless an admin set a different one\.`\]"
)
PASSWORD_HINT = re.compile(
    r"\[`On a fresh install you set the first admin's password yourself[^`]*`,` `,"
    r"\(0,\w+\.jsx\)\(`code`,\{className:`[^`]*`,children:`OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD`\}\),`\.`\]"
)


def _js(text: str) -> str:
    """A JS template literal holding *text* (no backticks / ${ in our copy)."""
    assert "`" not in text and "${" not in text
    return f"[`{text}`]"


USERNAME_COPY = _js(
    f"開通時建立的管理員帳號是 {ADMIN}；被邀請的同事請用自己註冊時設定的帳號。"
)
PASSWORD_COPY = _js(
    "管理員初始密碼於 WOOW 平台開通服務時一次性顯示，登入後請在帳號設定中修改。"
    "忘記密碼時，請其他管理員在成員管理中幫你重設。"
)

# One fixed bar per notice, stacked from the bottom (__BOTTOM__ px). Each is closed
# for the rest of the browser tab's session (sessionStorage, key __KEY__).
NOTICE_JS = """(function () {
  try { if (sessionStorage.getItem(__KEY__) === "1") return; } catch (e) {}
  function show() {
    if (document.getElementById(__ID__)) return;
    var bar = document.createElement("div");
    bar.id = __ID__;
    bar.setAttribute("role", "status");
    bar.style.cssText = "position:fixed;left:50%;bottom:__BOTTOM__px;transform:translateX(-50%);z-index:2147483647;" +
      "max-width:min(640px,calc(100vw - 32px));padding:12px 40px 12px 16px;border-radius:12px;" +
      "background:#fff7e6;color:#5c3b00;border:1px solid #f0c36d;box-shadow:0 4px 16px rgba(0,0,0,.15);" +
      "font:14px/1.6 system-ui,-apple-system,'Noto Sans TC',sans-serif";
    bar.textContent = __TEXT__;
    var x = document.createElement("button");
    x.type = "button";
    x.setAttribute("aria-label", "關閉");
    x.textContent = "×";
    x.style.cssText = "position:absolute;top:6px;right:10px;border:0;background:none;font-size:20px;cursor:pointer;color:inherit";
    x.onclick = function () {
      bar.remove();
      try { sessionStorage.setItem(__KEY__, "1"); } catch (e) {}
    };
    bar.appendChild(x);
    document.body.appendChild(bar);
  }
  if (document.body) show(); else document.addEventListener("DOMContentLoaded", show);
})();
"""
NOTICE_TEXT = (
    "尚未設定模型金鑰：雲端工作機（New Sandbox）上的工作階段送出後不會有回應。"
    "請到 WOOW 平台本服務的「設定」填入 OpenRouter 或 Anthropic API Key（儲存後服務約一分鐘重啟），"
    "或點輸入框左下的電腦圖示（主機選單），改選已用 omnigent host 接上的自己的機器。"
)
# #1451: the runner HOME (/home/omnigent, the session workspace) is an emptyDir.
EPHEMERAL_TEXT = (
    "提醒：雲端工作機（Kubernetes Sandbox）上的檔案是暫存的。工作機重建時——例如停止後再回到工作階段、"
    "閒置過久後恢復、建立滿 7 天、被驅逐或節點維護——工作區會清空，只保留對話紀錄。"
    "重要成果請隨時下載或推到 Git；需要長期保存的專案，請改用已用 omnigent host 接上的自己的機器。"
)

def patch_login() -> None:
    hits = {"username": 0, "password": 0}
    for path in sorted((DEST / "assets").glob("*.js")):
        text = path.read_text(encoding="utf-8")
        if "whoami" not in text and "OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD" not in text:
            continue
        new, n1 = USERNAME_HINT.subn(USERNAME_COPY, text)
        new, n2 = PASSWORD_HINT.subn(PASSWORD_COPY, new)
        hits["username"] += n1
        hits["password"] += n2
        if n1 or n2:
            path.write_text(new, encoding="utf-8")
            print(f"paas-webui: patched {path.name} (username={n1}, password={n2})")
    for name, n in hits.items():
        if not n:
            print(f"paas-webui: WARNING login {name} hint not found; upstream copy left as is")


def _add_notice(name: str, text: str, bottom: int) -> None:
    index = DEST / "index.html"
    html = index.read_text(encoding="utf-8")
    js = (
        NOTICE_JS.replace("__TEXT__", json.dumps(text, ensure_ascii=False))
        .replace("__ID__", json.dumps(f"woow-{name}-notice"))
        .replace("__KEY__", json.dumps(f"woow-{name}-notice-closed"))
        .replace("__BOTTOM__", str(bottom))
    )
    (DEST / f"woow-{name}-notice.js").write_text(js, encoding="utf-8")
    tag = f'<script src="./woow-{name}-notice.js" defer></script>'
    if "</head>" not in html:
        print(f"paas-webui: WARNING no </head> in index.html; {name} notice not added")
        return
    index.write_text(html.replace("</head>", f"    {tag}\n  </head>", 1), encoding="utf-8")
    print(f"paas-webui: {name} notice added")


def add_notice() -> None:
    """No LLM key configured: managed sessions cannot answer."""
    _add_notice("llm", NOTICE_TEXT, 16)


def add_ephemeral_notice() -> None:
    """#1451: cloud work machine files are temporary (stacked above the LLM one)."""
    _add_notice("workspace", EPHEMERAL_TEXT, 16 if LLM_CONFIGURED else 120)


def main() -> int:
    # Copy the children, not SRC itself: copystat on the emptyDir mount root is
    # not permitted for a non-root uid. Overwrites every file on an
    # init-container re-run, so patches never stack.
    for child in SRC.iterdir():
        if child.is_dir():
            shutil.copytree(child, DEST / child.name, dirs_exist_ok=True, copy_function=shutil.copyfile)
        else:
            shutil.copyfile(child, DEST / child.name)
    steps = (patch_login,) + (() if LLM_CONFIGURED else (add_notice,))
    steps += (add_ephemeral_notice,) if EPHEMERAL_WORKSPACE else ()
    for step in steps:
        try:
            step()
        except Exception as exc:  # noqa: BLE001 — best-effort, never block the server
            print(f"paas-webui: WARNING {step.__name__} failed: {exc!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
