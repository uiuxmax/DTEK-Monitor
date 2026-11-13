# Особиста macOS-збірка: встановлення та приймання

Інструкція для підготовленого `DTEKMonitor.app`. Актуальні докази, стан пакета
й посилання на нього — у [STATUS](../../STATUS.md). Публікація binary ще не
прийнята цим документом; source export і перевірений ZIP — різні результати.

Це **одна arm64-версія для Apple Silicon**, без Intel/Universal. M0–M8 у
плані — етапи розробки. Версія пакета 0.1.0, build 1; мінімальна macOS 13
задекларована в build, а runtime CI працює на macOS 15.8.2. Приймання всіх
систем від 13 і фізичних Mac ще відкрите. На Mac для запуску не потрібні
Xcode, Command Line Tools чи агент розробки.

## Після появи погодженого ZIP

1. Завантажити лише Mac arm64 ZIP і SHA256SUMS із погодженого випуску.
   За потреби звірити його штатним `shasum -a 256 <ZIP>` у Terminal.
2. Розпакувати Finder і перемістити `DTEKMonitor.app` у стабільне місце,
   рекомендовано `/Applications/DTEKMonitor.app`. Для перевірки автозапуску
   використовувати одну копію, не запускати її з тимчасової папки ZIP.
3. Відкрити `.app`. Це personal preview з ad-hoc signature, без Developer ID
   та notarization. Статичне `codesign --verify` не доводить Gatekeeper first
   launch. Для свідомо погодженого preview Apple описує разовий **Open Anyway**
   у [Privacy & Security](https://support.apple.com/102445).
4. Натиснути значок блискавки у menu bar. Якщо він недоступний через notch
   або переповнення рядка, повторно відкрити `.app` у Finder — має з'явитися
   вікно графіка в тому самому процесі. Закриття вікна залишає програму активною;
   **Вийти** завершує її.
5. Задати свою повну київську адресу. Підказка не підтверджує будинок або лінію:
   lookup окремо перевіряє street/house/group/schedule. Enter у списку обирає
   вулицю, Enter у полі будинку застосовує адресу; Escape скасовує форму.

Статус — груповий прогноз, а не виміряна наявність електроенергії на окремій
лінії. Завтра доступне лише за підтвердженої публікації. Countdown локальний;
відкриття попапа не виконує refresh. Плановий refresh — раз на 30 хвилин та
за нової київської доби, з перевіркою після wake/зміни часу. 403/429 зупиняють
автоматичні запити та підказки до наступної сесії. Повторне відкриття `.app`
через Finder саме собою сесію не перезапускає.

## Дані й автозапуск

Personal bundle ID — `local.dtekmonitor.Monitor`, protected UI —
`local.dtekmonitor.MonitorTest`. Personal profile:
`~/Library/Application Support/local.dtekmonitor.Monitor/`.
Windows settings/history не імпортуються. Зберігаються адреса, тема та
оригінальний денний receipt; failed refresh/restart не омолоджують timestamps.
Receipt припиняє діяти за київської півночі або неприйнятного clock rollback.
Діагностика має фіксовані коди без адрес/response bodies; її native приймання
відстежується окремо в STATUS. Канал автоматичних оновлень не активний.

Початково автозапуск **вимкнений**. Його вмикає користувач після встановлення
обраної копії. Галочка залежить від `SMAppService.status`, не saved preference:
enabled → увімкнено; requiresApproval → потрібна дія в параметрах macOS;
notRegistered → вимкнено; notFound/unknown → стан не підтверджений.
Повернення з системних параметрів перечитує status без повторної реєстрації.

Реєстрація ще не доводить sign-in запуск. Ad-hoc designated requirement
прив'язаний до конкретної версії коду за
[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
тому стабільність реєстрації після заміни preview потребує окремого тесту.
З цього не робиться висновок про гарантовану помилку або підтримку всіх
macOS. Справжні `register/unregister`, logout/login, external disable та update
потрібно прийняти на погодженій копії. CI використовує лише fake backend.

## Відкрите приймання на Mac

- [ ] Записати macOS/модель; перевірити отриманий ZIP, first launch і Gatekeeper.
- [ ] Зберегти адресу/тему, завершити та запустити `.app`; перевірити receipt.
- [ ] Окремо погодити live startup lookup і реальне 30-хвилинне спостереження.
- [ ] Sleep/wake в межах тієї ж доби, offline/online, київська північ та інша
  системна timezone — без паралельних або catch-up lookup.
- [ ] Keyboard/VoiceOver, Retina, зовнішній монітор, fullscreen/notch та
  переповнений menu bar. Ordinary use не потребує Accessibility/Screen Recording.
- [ ] Після погодження — увімкнення автозапуску, logout/login, системне
  вимкнення, заміна `.app` і duplicate-copy scenario.

Ці пункти не закриваються source checks, screenshots або synthetic CI PASS.

## Безкоштовна збірка

Standard hosted runner у public repository безкоштовний; artifact storage має
окрему квоту. Поточний workflow не використовує caches/uploads чи paid runners.
[Умови GitHub Actions](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
Release assets мають окрему модель зберігання без загального size/bandwidth
ліміту за [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
Публікація preview ZIP потребує окремого погодженого кроку; платна Apple
ідентичність/notarization не додається мовчки до безкоштовного варіанта.
