# App Store listing

Kept here so the listing changes go through review like code. Limits: name and subtitle 30,
keywords 100 (comma-separated, no spaces), promotional text 170, description 4000.

Shared fields: Privacy Policy URL https://relsett.github.io/voicefn/privacy/ ·
Support URL https://relsett.github.io/voicefn/support/ · Marketing URL https://relsett.github.io/voicefn/ ·
Category Productivity (secondary Utilities) · Price Free · Copyright 2026 Nikolai Kubarov

## English (U.S.)

**Name:** VoiceFn — Voice to Text

**Subtitle:** Press fn, speak, get text

**Keywords:** dictation,speech,transcribe,whisper,typing,mic,offline,ai,transcription,dictate,notes,writer

**Promotional text:** Dictate into any app on your Mac with one key. Recognized on device, private and free.

**Description:**

Press fn, speak, press fn again. Your words appear where the cursor is, in any app.

• On your Mac. Speech is recognized on device with Whisper. Nothing leaves your Mac, it works offline and it's free.
• Any app. Mail, Messages, Slack, Notes, a code editor, a browser: VoiceFn types into whatever is in front.
• Your key. fn by default; right Option or any shortcut if you prefer.
• History. Every dictation stays on your Mac, and a recording that didn't go through can be sent again.
• Your languages. English, Russian and dozens more.
• Quiet. A small capsule while you speak, a menu bar key, nothing else.

Prefer a cloud model? Connect your own OpenRouter account.

No account, no ads, no tracking.
Privacy Policy: https://relsett.github.io/voicefn/privacy/
Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/

## Russian

**Name:** VoiceFn — голос в текст

**Subtitle:** Нажмите fn и говорите

**Keywords:** диктовка,речь,распознавание,микрофон,whisper,набор,транскрибация,офлайн,заметки,ии,диктофон

**Promotional text:** Диктуйте в любое приложение на Mac одной клавишей. Распознавание прямо на Mac — приватно и бесплатно.

**Description:**

Нажмите fn, говорите, нажмите fn ещё раз. Текст появится там, где стоит курсор, в любом приложении.

• На вашем Mac. Речь распознаёт Whisper прямо на устройстве. Ничего не уходит с Mac, работает без интернета и бесплатно.
• Любое приложение. Почта, Сообщения, Slack, Заметки, редактор кода, браузер — VoiceFn печатает туда, что открыто.
• Ваша клавиша. По умолчанию fn; можно правый Option или любое сочетание.
• История. Все диктовки остаются на Mac, а запись, которая не прошла, можно отправить ещё раз.
• Ваши языки. Русский, английский и ещё десятки.
• Тихо. Маленькая капсула, пока вы говорите, клавиша в строке меню — и всё.

Хотите облачную модель? Подключите свой аккаунт OpenRouter.

Без аккаунта, рекламы и слежки.
Политика конфиденциальности: https://relsett.github.io/voicefn/privacy/
Условия использования: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/

## App Review notes

VoiceFn is a menu bar app (no Dock icon). Click the fn key icon in the menu bar → Settings.

1. Grant Microphone and Keyboard access when asked (the keyboard permissions are Post Event and
   Listen Event, used to notice the fn key and paste with ⌘V). macOS applies the keyboard grant after
   a relaunch; the app offers a Relaunch button for that.
2. Press fn (or right Option, chosen in Settings → Key), say a sentence, press fn again. The text is
   pasted into the frontmost text field.
3. Recognition "On This Mac" downloads Whisper (about 600 MB) on first launch; it needs no account.
4. OpenRouter is optional and needs the user's own OpenRouter account; Connect asks for consent first.

About com.apple.security.network.server: it is used only for OpenRouter sign-in (Settings → Recognition →
a model under OpenRouter → Connect). The app opens a temporary listener on 127.0.0.1 to receive the OAuth
PKCE redirect (RFC 8252 loopback), accepts that single request and closes within 3 minutes. Without it
the sandbox denies the bind and sign-in fails. No other incoming connections are accepted.
