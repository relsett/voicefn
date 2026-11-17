"""Builds App Store screenshot pages (1440x900 CSS px, rendered at 2x = 2880x1800)."""
import pathlib, sys

here = pathlib.Path(__file__).parent

TEXT = {
    "en": {
        "hero_h": "Press fn. Speak.<br>Press fn.",
        "hero_p": "Your words appear where the cursor is,<br>in any app.",
        "doc_title": "Notes",
        "doc_lines": ["Call with the design team, Thursday", "",
                      "Let's keep the capsule small and quiet, and only show words",
                      "when something needs the user's attention."],
        "local_h": "Recognized<br>on your Mac.",
        "local_p": "Private, offline and free.<br>Nothing leaves your Mac.",
    },
    "ru": {
        "hero_h": "Нажмите fn.<br>Говорите. Нажмите fn.",
        "hero_p": "Текст появится там, где курсор,<br>в любом приложении.",
        "doc_title": "Заметки",
        "doc_lines": ["Созвон с дизайнерами, четверг", "",
                      "Капсулу оставляем маленькой и тихой, а слова показываем",
                      "только когда от человека что-то нужно."],
        "local_h": "Распознаётся<br>на вашем Mac.",
        "local_p": "Приватно, без интернета и бесплатно.<br>Ничего не уходит с Mac.",
    },
}

STYLE = """
* { box-sizing: border-box; margin: 0; }
html, body { width: 1440px; height: 900px; overflow: hidden; }
body { background: radial-gradient(120% 120% at 20% 10%, #4a4c55 0%, #2a2b31 45%, #17181c 100%);
       color: #fff; font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif;
       display: flex; align-items: center; padding: 0 110px; gap: 80px; }
.copy { flex: 1; }
h1 { font-size: 64px; line-height: 1.08; font-weight: 700; letter-spacing: -0.5px; }
p { margin-top: 26px; font-size: 26px; line-height: 1.4; color: rgba(255,255,255,0.68); }
.key { width: 72px; height: 72px; border-radius: 16px; background: #3a3c43; margin-bottom: 40px;
       box-shadow: inset 0 1px 0 rgba(255,255,255,0.12), 0 10px 30px rgba(0,0,0,0.35);
       font-weight: 600; font-size: 22px; display: flex; justify-content: flex-end; padding: 10px 13px; }
.win { border-radius: 22px; overflow: hidden;
       box-shadow: 0 0 0 1px rgba(255,255,255,0.08), 0 40px 90px rgba(0,0,0,0.55); }
.win img { display: block; width: 560px; }
.doc { width: 660px; height: 440px; margin-top: -90px; background: #fbfbfa; color: #1d1d1f; border-radius: 18px; position: relative;
       box-shadow: 0 0 0 1px rgba(0,0,0,0.2), 0 40px 90px rgba(0,0,0,0.55); }
.bar { height: 52px; display: flex; align-items: center; gap: 9px; padding: 0 20px; border-bottom: 1px solid #e6e6e6; }
.dot { width: 13px; height: 13px; border-radius: 50%; }
.bar span { margin-left: 14px; font-size: 15px; font-weight: 600; color: #6e6e73; }
.text { padding: 34px 40px; font-size: 21px; line-height: 1.55; }
.text b { font-size: 26px; display: block; margin-bottom: 6px; }
.caret { display: inline-block; width: 2px; height: 24px; background: #ff616d; vertical-align: -4px; margin-left: 2px; }
.capsule { position: absolute; left: 50%; bottom: -150px; transform: translateX(-50%);
           width: 156px; height: 90px; border-radius: 45px; background: rgba(44,44,48,0.92);
           box-shadow: 0 0 0 1px rgba(255,255,255,0.10), 0 18px 40px rgba(0,0,0,0.45);
           display: flex; align-items: center; justify-content: center; gap: 7px; }
.capsule i { width: 7px; border-radius: 4px; background: rgb(255,97,110); display: block; }
"""

def page(body):
    return f"<!doctype html><meta charset=utf-8><style>{STYLE}</style><body>{body}</body>"

def hero(t):
    weights = [0.3, 0.6, 0.85, 1, 0.75, 0.5, 0.25]
    bars = "".join(f'<i style="height:{12 + w * 46:.0f}px"></i>' for w in weights)
    lines = t["doc_lines"]
    text = f"<b>{lines[0]}</b>" + " ".join(lines[2:]) + '<span class="caret"></span>'
    doc = (f'<div class="doc"><div class="bar"><div class="dot" style="background:#ff5f57"></div>'
           f'<div class="dot" style="background:#febc2e"></div><div class="dot" style="background:#28c840"></div>'
           f'<span>{t["doc_title"]}</span></div><div class="text">{text}</div>'
           f'<div class="capsule">{bars}</div></div>')
    return page(f'<div class="copy"><div class="key">fn</div><h1>{t["hero_h"]}</h1><p>{t["hero_p"]}</p></div>{doc}')

def settings(t, lang, kind):
    img = f"{lang}-store-settings-{kind}.png"
    return page(f'<div class="copy"><h1>{t[kind + "_h"]}</h1><p>{t[kind + "_p"]}</p></div>'
                f'<div class="win"><img src="{img}"></div>')

for lang, t in TEXT.items():
    (here / f"{lang}-1.html").write_text(hero(t))
    (here / f"{lang}-2.html").write_text(settings(t, lang, "local"))
print("ok")
